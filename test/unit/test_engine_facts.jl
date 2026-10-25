# ==============================================================================
# Engine facts dispatch, with no fallback (#1129 item 2, ahead of #1130)
#
# A branch that decided for two engines at once (`conn isa PormGPostgres ? A : B`) became a call to an
# ENGINE FACT: one method per engine, none for `PormGBackend` or `Any`. A third backend then gets a
# `MethodError` naming the fact it must decide, instead of silently taking another engine's arm. This
# file holds that contract for every fact, wherever it lives: `src/querybuilder/engine_facts.jl` and
# `src/migrations/engine_facts.jl` are read from the source, so a fact added there is checked without
# being listed here; the facts that live beside the code they serve (Kernel, `Dialect`,
# `ConnectionPool`, `explain`, deletion, `inspectdb`, `check`) are listed.
#
# Run: julia --project=test/integration test/unit/test_engine_facts.jl
# ==============================================================================

using Test
using PormG

const _EF_QB = PormG.QueryBuilder
struct _EfPg <: PormG.PormGPostgres end
struct _EfSl <: PormG.PormGSQLite end
struct _EfMy <: PormG.PormGMySQL end
struct _EfOther <: PormG.PormGBackend end   # a backend that has decided nothing yet, as #1130 starts

# Every top-level `name(…) =` / `function name(` in a facts file: the registry is the file itself.
function _ef_file_facts(parts...)
  path = joinpath(pkgdir(PormG), "src", parts..., "engine_facts.jl")
  names = Symbol[]
  open(path) do io
    for l in eachline(io)
      m = match(r"^(?:function\s+)?(_[A-Za-z0-9_]+)\(", l)
      m === nothing || push!(names, Symbol(m.captures[1]))
    end
  end
  return unique(names)
end

const _EF_MIG = PormG.Migrations
const _EF_FACTS = vcat(
  [(_EF_QB, n) for n in _ef_file_facts("querybuilder")],
  [(_EF_MIG, n) for n in _ef_file_facts("migrations")],
  [(PormG.Kernel, :_engine_key),                    # the engine's NamedTuple key / report label
   (PormG.Dialect, :_parenthesizes_db_default),     # a DEFAULT expression needs parens
   (PormG.ConnectionPool, :_begin_write_sql),       # how a write transaction opens
   (PormG.ConnectionPool, :_after_begin_sql),       # what runs right after it
   (PormG.ConnectionPool, :_execute_async),         # which driver path a statement runs through
   (PormG.ConnectionPool, :_acquire_in_mode),       # how a connection is leased for a mode
   (PormG.ConnectionPool, :_acquire_for_statement), # … and for one statement
   (_EF_MIG, :_inspectdb_id_pk),                    # inspectdb's fall-through primary key
   (_EF_MIG, :_expression_default_findings),        # check(): expression defaults
   (_EF_MIG, :_invalid_index_findings),             # check(): invalid indexes
   (_EF_QB, :_explain_sql),                         # the EXPLAIN statement
   (_EF_QB, :_explain_facts),                       # the facts read from its rows
   (_EF_QB, :_affected_row_count),                  # the rows a DELETE / bulk UPDATE matched
   (_EF_QB, :_computed_kind)],                      # the type a function computes (#1034, beside each constructor)
)

# The engine a method parameter names: `:postgres`, `:sqlite`, `:mysql`, or `nothing` for a non-engine one.
_ef_engine(T) = T isa Type && T <: PormG.PormGPostgres ? :postgres :
                T isa Type && T <: PormG.PormGSQLite ? :sqlite :
                T isa Type && T <: PormG.PormGMySQL ? :mysql : nothing

# The facts MySQL (#1130) has decided so far, each in the phase that needs it. Phase 1 decides the
# connection's: its key, how its transactions open, and how its statements run and lease. Every other
# fact stays undecided — a `MethodError` naming it — until its phase adds it here, so a MySQL method
# that appears without being listed (or a listed one that disappears) fails below.
const _EF_MYSQL_DECIDED = Set([:_engine_key, :_begin_write_sql, :_after_begin_sql, :_execute_async,
                               :_acquire_in_mode, :_acquire_for_statement,
                               # Phase 2a (plain-column reads): what every filter, ordering, list
                               # membership and `inspect_query` asks.
                               :_interval_as_ms, :_casts_bind_parameters, :_emulates_nulls_order,
                               :_binds_list_as_array, :_inspection_dialect,
                               # ... row locks, aggregates, and what a function render asks first.
                               :_locks_rows, :_sums_integers_as_decimal, :_greatest_skips_nulls,
                               :_computed_kind,
                               # Phase 2b (expressions): a quotient over a `Sum` the walk cannot name.
                               :_untyped_sum_departs, :_cast_renders_text, :_casts_bigint_day_count,
                               # Phase 2b intervals: the integer an interval is computed in.
                               :_interval_unit_ns, :_stores_interval_as_units,
                               # #1310: MySQL computes a date as the number its digits spell, so an
                               # operand the walk cannot name is refused beside one there.
                               :_types_temporal_operands,
                               # #1110: MySQL applies a declared decimal itself (it clamps an overflow).
                               :_unapplied_decimal_width,
                               # Phase 2c-1: a boolean declaration MySQL has no cast target for.
                               :_normalizes_boolean_cast,
                               # Phase 3a (single-row writes and deletes): no RETURNING, the row read
                               # back by its key, the matched-row counts, the parent locks, and the
                               # 1093 wrap around a subquery on the table a mutation writes.
                               :_insert_returns_rows, :_inserted_row_query, :_update_row_count,
                               :_update_from_sql, :_affected_row_count, :_locks_cascade_parents,
                               :_materializes_target_key_set, :_assigns_set_in_order,
                               # Phase 3b (upserts): a miss serialized by nothing but the unique
                               # index.
                               :_serializes_get_or_create,
                               # Phase 3c-1 (bulk_insert): one parameter per cell, no identity to
                               # override, no keys drawn ahead, and the skips read from the report.
                               :_bulk_binds_column_arrays, :_overrides_generated_identity, :_allocate_ids,
                               :_allocates_ids_in_transaction, :_counts_skips_from_report,
                               # Phase 3c-2 (bulk_update): a `VALUES ROW(…)` derived table.
                               :_values_row_prefix,
                               # Phase 4a (migrations on a schema created from nothing): alters in
                               # place, adopts no index it did not create, compares index names
                               # case-insensitively, its own ignore list, a parenthesized DEFAULT
                               # expression, and check()'s two engine readers.
                               :_rebuilds_table, :_adopts_indexes, :_composite_name_key,
                               :_builtin_ignore_tables, :_builtin_ignore_tables_name,
                               :_parenthesizes_db_default, :_expression_default_findings,
                               :_invalid_index_findings, :_can_rename_index,
                               # Phase 4b: what the row pre-checks count, a retype's cast rules, and
                               # what a dropped column takes with it.
                               :_pk_precheck_counts_nulls, :_no_implicit_cast, :_retype_drops_default,
                               :_negative_value_predicate, :_byte_length_predicate,
                               :_drop_column_drops_its_indexes,
                               # Phase 4c: what `inspectdb` declares for a key and the integer and
                               # timestamp types.
                               :_text_key_is_uuid, :_declares_bigint, :_declares_naive_timestamp,
                               :_inspectdb_id_pk])

# ─────────────────────────────────────────────────────────────────────────────
# Engine facts: the registry read from the facts file is not empty and names real functions
# Guards the guard: if the file's definitions stopped matching the scan (a rename to a different
# spelling, a moved file), every check below would pass vacuously over an empty list.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1129: the engine-fact registry is read from both engine_facts.jl files" begin
  file_facts = _ef_file_facts("querybuilder")
  @test length(file_facts) >= 15
  @test :_interval_as_ms in file_facts && :_insert_returns_rows in file_facts
  mig_facts = _ef_file_facts("migrations")
  @test length(mig_facts) >= 12
  @test :_rebuilds_table in mig_facts && :_builtin_ignore_tables in mig_facts
  for (mod, name) in _EF_FACTS
    @test isdefined(mod, name)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Engine facts: one method per engine, and no method a third backend could fall into
# Every method of every fact names an engine in its signature, and together they cover PostgreSQL and
# SQLite — and MySQL exactly for the facts it has decided. A method on `PormGBackend`, `Any` or an
# untyped argument would be a default — exactly the silent arm the facts replaced — so its absence is
# the point.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1129: every engine fact has a PostgreSQL and a SQLite method and no fallback" begin
  for (mod, name) in _EF_FACTS
    f = getfield(mod, name)
    covered = Set{Symbol}()
    for m in methods(f)
      params = Base.unwrap_unionall(m.sig).parameters[2:end]
      engines = filter(!isnothing, map(_ef_engine, params))
      # This method is engine-specific (it names one), so it is not a fallback.
      @test (name, m.line, !isempty(engines)) == (name, m.line, true)
      union!(covered, engines)
    end
    expected = name in _EF_MYSQL_DECIDED ? [:mysql, :postgres, :sqlite] : [:postgres, :sqlite]
    @test (name, sort!(collect(covered))) == (name, expected)
  end
  # Guards the guard: every name MySQL is said to have decided is a registered fact.
  @test _EF_MYSQL_DECIDED ⊆ Set(last.(_EF_FACTS))
end

# ─────────────────────────────────────────────────────────────────────────────
# Engine facts: a third backend gets a MethodError at each fact
# Each method's signature with its engine parameter swapped for a backend that subtypes neither
# engine must have no method to call, so #1130's first call into a fact fails loudly at that fact.
# One fact is also CALLED, to show the failure is a MethodError and not something caught upstream.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1129: a backend that is neither PostgreSQL nor SQLite has no method at any engine fact" begin
  for (mod, name) in _EF_FACTS
    f = getfield(mod, name)
    for m in methods(f)
      params = collect(Base.unwrap_unionall(m.sig).parameters[2:end])
      swapped = Any[_ef_engine(T) === nothing ? T : _EfOther for T in params]
      @test (name, hasmethod(f, Tuple{swapped...})) == (name, false)
    end
  end
  @test_throws MethodError _EF_QB._interval_as_ms(_EfOther())
  @test_throws MethodError PormG.Kernel._engine_key(_EfOther())
  # #1034 phase 3 step 2a: what a function computes was "unknown" on any other backend until its
  # fallback was deleted; the division refusal's departure is a fact of its own.
  @test_throws MethodError _EF_QB._computed_kind(Val(:SUM), :promoting, PormG.CInt64(), _EfOther())
  @test_throws MethodError _EF_QB._untyped_sum_departs(_EfOther())
  @test _EF_QB._untyped_sum_departs(_EfPg()) && !_EF_QB._untyped_sum_departs(_EfSl())
  # Sanity on the two engines: the facts answer, and answer differently where they should.
  @test _EF_QB._interval_as_ms(_EfSl()) && !_EF_QB._interval_as_ms(_EfPg())
  @test PormG.Kernel._engine_key(_EfPg()) === :postgres && PormG.Kernel._engine_key(_EfSl()) === :sqlite
  # MySQL (#1130): the facts phases 1 and 2a decided answer; an undecided one is still a MethodError.
  @test PormG.Kernel._engine_key(_EfMy()) === :mysql
  @test PormG.ConnectionPool._begin_write_sql(_EfMy()) == "START TRANSACTION;"
  @test PormG.ConnectionPool._after_begin_sql(_EfMy()) == String[]
  @test _EF_QB._interval_as_ms(_EfMy()) && _EF_QB._emulates_nulls_order(_EfMy())
  # An interval is an integer of microseconds there, and it is the stored value itself (#1130).
  @test _EF_QB._interval_unit_ns(_EfMy()) == 1_000 && _EF_QB._interval_unit_ns(_EfSl()) == 1_000_000
  @test _EF_QB._stores_interval_as_units(_EfMy()) && !_EF_QB._stores_interval_as_units(_EfSl())
  @test !_EF_QB._casts_bind_parameters(_EfMy()) && !_EF_QB._binds_list_as_array(_EfMy())
  @test _EF_QB._inspection_dialect(_EfMy()) == (:mysql, :positional)
  # `_stores_date_as_text` stays SQLite's question: MySQL refuses an untyped date operand by a method of
  # its own (`_untyped_date_refusal`, phase 2b), since its `+` reads a date's digits, not its text.
  @test_throws MethodError _EF_QB._stores_date_as_text(_EfMy())
  # Phase 3a: MySQL has no RETURNING, and reads a mutation's own table through a derived table.
  @test !_EF_QB._insert_returns_rows(_EfMy()) && _EF_QB._materializes_target_key_set(_EfMy())
  @test !_EF_QB._materializes_target_key_set(_EfPg()) && !_EF_QB._materializes_target_key_set(_EfSl())
  # Phase 3b: no lock between the get and the insert.
  @test !_EF_QB._serializes_get_or_create(_EfMy())
  # Phase 3c-1: a bulk INSERT binds one parameter per cell, and counts its skips from MySQL's report.
  @test !_EF_QB._bulk_binds_column_arrays(_EfMy()) && _EF_QB._counts_skips_from_report(_EfMy())
  # Phase 4a: MySQL alters in place, renames an index in place, and adopts no index it did not create;
  # phase 4b: MODIFY converts a pair unless the rule changes every value, a retype drops an undeclared
  # expression default, and a dropped column narrows its indexes; phase 4c: `inspectdb` reads a `CHAR(36)`
  # key as a uuid (no text key), a `BIGINT` as a `BigIntegerField`, a `DATETIME` as the default `DateTimeField`.
  @test !PormG.Migrations._rebuilds_table(_EfMy()) && !PormG.Migrations._adopts_indexes(_EfMy())
  @test PormG.Migrations._can_rename_index(_EfMy())
  @test PormG.Migrations._composite_name_key(_EfMy(), "Result_Idx") == "result_idx"
  @test !PormG.Migrations._no_implicit_cast(_EfMy(), PormG.CInt32(), PormG.CText()) &&
        PormG.Migrations._no_implicit_cast(_EfMy(), PormG.CDate(), PormG.CTime()) &&
        PormG.Migrations._retype_drops_default(_EfMy(), PormG.CText(), PormG.CInt32())
  @test !PormG.Migrations._drop_column_drops_its_indexes(_EfMy()) &&
        PormG.Migrations._drop_column_drops_its_indexes(_EfPg()) && PormG.Migrations._drop_column_drops_its_indexes(_EfSl())
  @test PormG.Migrations._byte_length_predicate(_EfMy(), "`b`", "?") == "LENGTH(`b`) > ?"
  @test !PormG.Migrations._text_key_is_uuid(_EfMy()) && PormG.Migrations._declares_bigint(_EfMy()) &&
        !PormG.Migrations._declares_naive_timestamp(_EfMy())
end
