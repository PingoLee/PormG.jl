# ─────────────────────────────────────────────────────────────────────────────
# Column-aware secondary-index preservation for the SQLite table rebuild (#116)
#
# Deleting a ForeignKey field on SQLite can't use `ALTER TABLE DROP COLUMN` (SQLite
# refuses a column bound by a FOREIGN KEY), so PormG rebuilds the table from the
# desired model — create new / INSERT…SELECT / drop / rename — and re-creates the
# table's secondary indexes afterward. `get_secondary_index_ddls` snapshots those
# index DDLs from the LIVE schema at planning time; if the rebuild dropped a column,
# re-creating an index that references it would raise SQLite "no such column" (the
# exact crash Django hit — ticket #33899).
#
# The `surviving_columns` kwarg fixes that: an index is preserved only when every one
# of its columns still exists in the rebuilt table. It probes each index's exact
# column membership via `pragma_index_info` (robust vs. substring-matching the DDL).
# `nothing` (the default) disables filtering — the pre-#116 "copy every live index"
# behavior every pure-alteration rebuild still relies on.
#
# Hermetic temp SQLite DB (same pattern as test_ignore_tables_registry.jl); no live
# integration DB. Mutation gate: dropping the filter makes the `Set(["a","c"])` case
# below return all three indexes instead of just the one on the surviving column.
# ─────────────────────────────────────────────────────────────────────────────
using Test
using PormG
using DataFrames
import PormG.ConnectionPool: SQLiteConnectionPool, fetch, close_pool!
import PormG.Migrations: get_secondary_index_ddls, _sqlite_column_is_unique

@testset "get_secondary_index_ddls column filter (#116)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "idxfilter.sqlite"); pool_size = 1)
    try
      fetch(pool, "CREATE TABLE t (a INTEGER, b INTEGER, c INTEGER);")
      fetch(pool, "CREATE INDEX ia ON t(a);")          # single column a
      fetch(pool, "CREATE INDEX ib ON t(b);")          # single column b
      fetch(pool, "CREATE INDEX iab ON t(a, b);")      # multi-column: a AND b

      # Baseline — no kwarg → every live secondary index is preserved (pre-#116 behavior).
      all_ddls = get_secondary_index_ddls(pool, "t")
      @test length(all_ddls) == 3
      @test any(occursin("ia", d) for d in all_ddls)
      @test any(occursin("ib", d) for d in all_ddls)
      @test any(occursin("iab", d) for d in all_ddls)

      # The #116 fix — column `b` was removed by the rebuild (surviving = {a, c}). Any index
      # touching `b` must be filtered so it isn't re-created against a now-missing column:
      #   ia(a)     → kept   (a survives)
      #   ib(b)     → dropped (b gone)
      #   iab(a, b) → dropped (b gone, even though a survives)
      kept = get_secondary_index_ddls(pool, "t"; surviving_columns = Set(["a", "c"]))
      @test length(kept) == 1
      @test occursin("ia", kept[1])
      @test !any(occursin("ib", d) for d in kept)      # single-column index on dropped col
      @test !any(occursin("iab", d) for d in kept)     # multi-column index touching dropped col

      # Passing the kwarg but dropping nothing (surviving ⊇ every column) filters nothing —
      # proves the filter removes indexes ONLY for genuinely-absent columns (no false drops on
      # the pure-alteration path, where existing rebuild tests must stay green).
      kept_all = get_secondary_index_ddls(pool, "t"; surviving_columns = Set(["a", "b", "c"]))
      @test length(kept_all) == 3
    finally
      # Release the SQLite handle so mktempdir can delete the temp DB on Windows (WAL keeps it open).
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #150: rename-aware index preservation via the `column_renames` kwarg.
#
# When a rename-with-FK-change rebuilds the table, `get_secondary_index_ddls` still
# snapshots the LIVE (pre-rename) index DDL — with the OLD column name — but the
# rebuilt table carries the NEW name. `column_renames` (old ⇒ new) maps each renamed
# column so its index (a) survives the `surviving_columns` filter (keyed on the NEW
# names) and (b) is re-created with the new column name. PormG emits quoted
# identifiers (create_index in Dialect.jl), so the rewrite targets the quoted `"old"`
# token — precise enough to leave an index NAME that merely contains the column
# substring untouched.
# ─────────────────────────────────────────────────────────────────────────────
@testset "get_secondary_index_ddls column_renames (#150)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "idxrename.sqlite"); pool_size = 1)
    try
      fetch(pool, "CREATE TABLE t (old_col INTEGER, keep INTEGER);")
      # Index name deliberately CONTAINS the column substring, to prove the quoted-token
      # rewrite touches only the parenthesised column reference, never the name.
      fetch(pool, "CREATE INDEX \"old_col_ix\" ON \"t\" (\"old_col\");")
      fetch(pool, "CREATE INDEX \"multi_ix\" ON \"t\" (\"old_col\", \"keep\");")

      renames = Dict("old_col" => "new_col")
      surviving = Set(["new_col", "keep"])   # the rebuilt table's physical columns (post-rename)

      # Without the map, `surviving` is keyed on the NEW names while the live index still
      # references `old_col`, so BOTH indexes are filtered out — i.e. the renamed column's
      # index would be silently lost. This is exactly what column_renames must prevent.
      lost = get_secondary_index_ddls(pool, "t"; surviving_columns = surviving)
      @test isempty(lost)

      # With the map: both indexes survive (old_col maps onto the surviving new_col) and the
      # emitted DDL references the NEW column name.
      kept = get_secondary_index_ddls(pool, "t"; surviving_columns = surviving, column_renames = renames)
      @test length(kept) == 2
      for ddl in kept
        @test occursin("\"new_col\"", ddl)      # column rewritten to the new name
        @test !occursin("\"old_col\"", ddl)     # no bare old-column ref remains (name is not a match)
      end
      # The index NAME "old_col_ix" (contains the substring) is preserved verbatim — the
      # quoted-token rewrite matched only the column, never the name.
      @test any(occursin("\"old_col_ix\"", d) for d in kept)
      @test any(occursin("\"keep\"", d) for d in kept)   # untouched column in the multi-col index

      # Mutation gate: drop the DDL rewrite and `"old_col"` stays in the output → the
      # `!occursin("\"old_col\"")` checks fail. Drop the filter mapping and `kept` goes empty.
    finally
      # Release the SQLite handle so mktempdir can delete the temp DB on Windows (WAL keeps it open).
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #151: `_sqlite_column_is_unique` — the live-schema probe that decides whether deleting a non-FK column
# needs a table rebuild.
#
# SQLite refuses `ALTER TABLE DROP COLUMN` for a UNIQUE column, and its backing `sqlite_autoindex_…` can't
# be pre-dropped with `DROP INDEX` — so such a deletion must route through a rebuild. SQLite introspection
# does NOT populate `field.unique`, so the deletion path can't trust the old field's attribute; it probes
# the live schema instead. This probe must fire for a column-level `UNIQUE` (auto-index) but NOT for an
# ordinary secondary index (whose column CAN take DROP COLUMN once the plain index is pre-dropped).
# ─────────────────────────────────────────────────────────────────────────────
@testset "_sqlite_column_is_unique (#151)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "uniqueprobe.sqlite"); pool_size = 1)
    try
      # `uc` has a column-level UNIQUE (→ sqlite_autoindex); `ic` has a plain CREATE INDEX; `plain` has none.
      fetch(pool, "CREATE TABLE t (uc TEXT UNIQUE, ic INTEGER, plain TEXT);")
      fetch(pool, "CREATE INDEX ix_ic ON t(ic);")

      @test _sqlite_column_is_unique(pool, :t, "uc") == true      # UNIQUE column → rebuild required
      @test _sqlite_column_is_unique(pool, :t, "ic") == false     # plain index → cheap DROP COLUMN is fine
      @test _sqlite_column_is_unique(pool, :t, "plain") == false  # no index → cheap DROP COLUMN is fine
      @test _sqlite_column_is_unique(pool, :t, "absent") == false # unknown column → false, never throws

      # Also true for an explicit CREATE UNIQUE INDEX (still a UNIQUE index covering the column).
      fetch(pool, "CREATE UNIQUE INDEX ux_plain ON t(plain);")
      @test _sqlite_column_is_unique(pool, :t, "plain") == true
      # Mutation gate: without the `row.unique == 1` filter, `ic` (plain index) would return true.
    finally
      close_pool!(pool)
    end
  end
end
