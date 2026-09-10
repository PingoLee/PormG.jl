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
using Logging
using PormG
using DataFrames
import PormG.ConnectionPool: SQLiteConnectionPool, fetch, close_pool!
import PormG.Migrations: get_secondary_index_ddls, _sqlite_column_is_unique,
                         _sqlite_single_column_unique_columns,
                         _sqlite_single_column_indexed_columns, _sqlite_composite_indexes,
                         convertSQLToModel, get_constraints_index,
                         _sqlite_identifier_tokens, _sqlite_index_argument_region,
                         _sqlite_index_referenced_columns, _sqlite_indexes_referencing_column,
                         _sqlite_index_is_unmodellable
import PormG: PormGModel
# The #519 testsets open a real (temporary) SQLite file and plan against it. `runtests.jl` loads the
# weakdep extension for the whole suite; this guard is what makes the file runnable on its own.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))

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
# be pre-dropped with `DROP INDEX` — so such a deletion must route through a rebuild. The deletion path
# probes the live schema rather than reading `old_field.unique`, and STILL must after #318 gave
# introspection a `unique` flag: that flag is narrow by design (single-column UNIQUE *constraints*), while
# this probe must answer the broader "is the column in ANY unique index?" — composite members and
# `CREATE UNIQUE INDEX` columns included. This probe must fire for a column-level `UNIQUE` (auto-index) but
# NOT for an ordinary secondary index (whose column CAN take DROP COLUMN once the plain index is pre-dropped).
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

# ─────────────────────────────────────────────────────────────────────────────
# #318: `_sqlite_single_column_unique_columns` — the NARROW sibling of the probe above, and the one
# introspection uses to populate `field.unique`.
#
# `PRAGMA table_info` has no uniqueness column at all, so introspection never set `unique`: a model
# declaring `unique=true` never compared equal to its own live table and `makemigrations` proposed the
# same rebuild forever. This function answers a deliberately DIFFERENT question from the #151 probe —
# "does this column carry a single-column UNIQUE *constraint*?", i.e. exactly what `field.unique`
# emits — so the two must not be collapsed into one.
#
# Each filter has a distinct mutation gate, spelled out per assertion below.
# ─────────────────────────────────────────────────────────────────────────────
@testset "_sqlite_single_column_unique_columns (#318)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "uniquecols.sqlite"); pool_size = 1)
    try
      # One of every shape that PRAGMA index_list can report:
      #   uc     → column-level UNIQUE      (origin 'u', 1 col)  ← the ONLY one that is field.unique
      #   a, b   → table-level UNIQUE(a,b)  (origin 'u', 2 cols)
      #   plain  → CREATE UNIQUE INDEX      (origin 'c')
      #   ic     → plain CREATE INDEX       (not unique)
      #   id     → INTEGER PRIMARY KEY      (origin 'pk', or no index at all for a rowid alias)
      fetch(pool, "CREATE TABLE t (id INTEGER PRIMARY KEY, uc TEXT UNIQUE, ic INTEGER, plain TEXT, a TEXT, b TEXT, UNIQUE(a,b));")
      fetch(pool, "CREATE INDEX ix_ic ON t(ic);")
      fetch(pool, "CREATE UNIQUE INDEX ux_plain ON t(plain);")

      cols = _sqlite_single_column_unique_columns(pool, :t)
      @test cols == Set(["uc"])

      # Spelled out individually so a failure names the filter that broke:
      @test "uc" in cols        # drop `il."unique" = 1` and `ic` leaks in
      @test !("a" in cols)      # drop `HAVING COUNT(*) = 1` and composite members leak in — they are
      @test !("b" in cols)      #   model-level UniqueConstraint (#19), never a per-field attribute
      @test !("plain" in cols)  # drop `origin = 'u'` and CREATE UNIQUE INDEX leaks in — that is how a
                                #   single-field UniqueConstraint is materialized, and marking it would
                                #   churn in the opposite direction (and diverge from PostgreSQL, whose
                                #   pg_constraint read cannot see a bare index either)
      @test !("ic" in cols)
      @test !("id" in cols)     # a PK is already an IDField; introspection must never touch it (and
                                #   sIDField is immutable, so setting `unique` on it would throw)

      # An unknown table yields an empty set rather than throwing — convert_schema_to_models calls this
      # per table and must not blow up on a race with a concurrent DROP.
      @test _sqlite_single_column_unique_columns(pool, :nonexistent) == Set{String}()

      # The #151 probe's BROAD semantics are untouched by all of the above — this is the assertion that
      # proves the two functions were not accidentally merged.
      @test _sqlite_column_is_unique(pool, :t, "uc") == true
      @test _sqlite_column_is_unique(pool, :t, "plain") == true   # CREATE UNIQUE INDEX
      @test _sqlite_column_is_unique(pool, :t, "a") == true       # composite member
      @test _sqlite_column_is_unique(pool, :t, "ic") == false

      # END TO END: the set above is only useful if convertSQLToModel actually applies it. Without
      # this, the whole fix could be inert and every assertion above would still pass.
      m = convertSQLToModel(pool, "t")
      @test m.fields["uc"].unique
      @test !m.fields["plain"].unique
      @test !m.fields["a"].unique
      @test !m.fields["ic"].unique
      @test m.fields["id"] isa PormG.Models.sIDField   # PK branch untouched (and immutable)

      # A UNIQUE foreign key gets the `unique` flag like any other column AND, since #417, comes back
      # as a `OneToOneField` — the same type the PostgreSQL reader has always produced for it.
      #
      # This assertion is the inverse of what it pinned under #318, and deliberately so. #318
      # withheld the O2O because PormG could not materialize one: `Dialect._get_column_type` had no
      # branch for it and the inline FK clause was gated on `isa sForeignKey`, so returning one made
      # the inspectdb round trip strictly WORSE — `INTEGER` + a foreign key regenerated as `TEXT` +
      # no foreign key. #408 fixed both halves, which removed the objection, and #417 took the
      # decision the #318 comment said belonged in its own issue. The cross-reader agreement itself
      # is asserted in `test_key_type_round_trip.jl`; what is pinned HERE is that the uniqueness
      # signal this file is about (`_sqlite_single_column_unique_columns`) is what drives it.
      fetch(pool, "CREATE TABLE parent318 (id INTEGER PRIMARY KEY, nome TEXT);")
      fetch(pool, """CREATE TABLE child318 (
        id INTEGER PRIMARY KEY,
        o2o INTEGER UNIQUE REFERENCES parent318(id),
        fk  INTEGER REFERENCES parent318(id));""")
      c = convertSQLToModel(pool, "child318")
      @test c.fields["o2o"] isa PormG.Models.sOneToOneField
      @test c.fields["o2o"].unique        # …the uniqueness IS read, which is what #318 fixed
      @test !c.fields["o2o"].primary_key  # a one-to-one, not the pk-fk shape #409 covers
      # The control that keeps the promotion honest: a NON-unique foreign key in the same table
      # must stay a plain ForeignKey. Without this, "always return OneToOneField" would pass.
      @test c.fields["fk"]  isa PormG.Models.sForeignKey
      @test !(c.fields["fk"] isa PormG.Models.sOneToOneField)
      @test !c.fields["fk"].unique
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #325: `_sqlite_single_column_indexed_columns` — the `db_index` twin of the #318 `unique` reader
#
# `PRAGMA table_info` carries neither attribute, so introspection never populated `db_index` on
# SQLite at all. Every `db_index=true` field (SlugField defaults to it) therefore compared unequal
# to its own live table forever — and since `Dialect.alter_field` has no `db_index` branch, the
# rebuild it triggered emitted no DDL for it. `src/migrations/planner.jl` carried a workaround for
# one symptom of that; this is the cause.
#
# The filters are the mirror image of the `unique` reader's, and each excludes an index that is NOT
# `db_index`. Every assertion below names the filter it gates.
# ─────────────────────────────────────────────────────────────────────────────
@testset "_sqlite_single_column_indexed_columns (#325)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "indexedcols.sqlite"); pool_size = 1)
    try
      # One of every shape PRAGMA index_list reports, mirrored from the #318 fixture above:
      #   ix     → plain CREATE INDEX        (origin 'c', unique 0, 1 col)  ← the ONLY db_index
      #   uc     → column-level UNIQUE       (origin 'u')
      #   plain  → CREATE UNIQUE INDEX       (origin 'c', unique 1)
      #   a, b   → composite CREATE INDEX    (origin 'c', unique 0, 2 cols)
      #   part   → partial CREATE INDEX      (origin 'c', unique 0, 1 col, partial 1)
      fetch(pool, """CREATE TABLE t325 (
        id INTEGER PRIMARY KEY, ix TEXT, uc TEXT UNIQUE, plain TEXT,
        a TEXT, b TEXT, part TEXT);""")
      fetch(pool, "CREATE INDEX ix_t325_ix ON t325(ix);")
      fetch(pool, "CREATE UNIQUE INDEX ux_t325_plain ON t325(plain);")
      fetch(pool, "CREATE INDEX ix_t325_ab ON t325(a, b);")
      fetch(pool, "CREATE INDEX ix_t325_part ON t325(part) WHERE part IS NOT NULL;")

      idx = _sqlite_single_column_indexed_columns(pool, :t325)
      @test collect(keys(idx)) == ["ix"]
      # The index NAME is carried too — the planner needs it to DROP the index when a model stops
      # declaring `db_index`, and SQLite's reader never populated `cache["index"]` before.
      @test idx["ix"] == "ix_t325_ix"

      # Spelled out individually so a failure names the filter that broke:
      @test haskey(idx, "ix")         # drop `origin = 'c'` and the UNIQUE auto-index leaks in
      @test !haskey(idx, "uc")        # a column-level UNIQUE is `field.unique` (#318), not db_index
      @test !haskey(idx, "plain")     # drop `il."unique" = 0` and CREATE UNIQUE INDEX leaks in —
                                      #   that is how a single-field UniqueConstraint (#19) is
                                      #   materialized, and marking it would churn the other way
      @test !haskey(idx, "a")         # drop `HAVING COUNT(*) = 1` and composite members leak in;
      @test !haskey(idx, "b")         #   PormG only ever indexes one column per db_index
      @test !haskey(idx, "part")      # drop `il.partial = 0` and a partial index leaks in — it
                                      #   constrains rows, not the column, and PormG cannot declare
                                      #   one, so reading it would be permanent churn
      @test !haskey(idx, "id")        # a PK is already an IDField (and sIDField is immutable)

      # An unknown table yields an empty dict rather than throwing — convert_schema_to_models calls
      # this per table and must survive a race with a concurrent DROP.
      @test _sqlite_single_column_indexed_columns(pool, :nonexistent) == Dict{String, String}()

      # END TO END: the dict is only useful if convertSQLToModel applies it. Without this the whole
      # fix could be inert and every assertion above would still pass.
      m = convertSQLToModel(pool, "t325")
      @test m.fields["ix"].db_index
      @test !m.fields["uc"].db_index
      @test !m.fields["plain"].db_index
      @test !m.fields["a"].db_index
      @test !m.fields["part"].db_index
      @test m.cache["index"]["ix"] == "ix_t325_ix"

      # ── The other half of #325 on SQLite: a bare TEXT column must not invent a max_length ──
      # SQLite renders CharField as `TEXT(n)` and UUIDField/JSONField/ImageField/TextField all as
      # bare `TEXT`. Reading a lengthless `TEXT` back as `CharField` meant the constructor's default
      # `max_length = 250` was invented from nothing — the model rendered `TEXT`, the "live" model
      # rendered `TEXT(250)`, and the two never matched.
      fetch(pool, """CREATE TABLE len325 (
        id INTEGER PRIMARY KEY, bare TEXT, sized TEXT(120), vc VARCHAR(64));""")
      lm = convertSQLToModel(pool, "len325")

      @test lm.fields["bare"] isa PormG.Models.sTextField      # ← the mutation gate
      @test !hasfield(typeof(lm.fields["bare"]), :max_length)  # nothing left to invent

      # A declared length still means CharField, carrying that exact length — the fix must not
      # swing the other way and turn every textual column into a TextField.
      @test lm.fields["sized"] isa PormG.Models.sCharField
      @test lm.fields["sized"].max_length == 120
      # VARCHAR/CHAR are accepted for schemas PormG did not create; before #325 a hand-written
      # `VARCHAR(64)` fell through to TextField and lost its length outright.
      @test lm.fields["vc"] isa PormG.Models.sCharField
      @test lm.fields["vc"].max_length == 64
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #347: `_sqlite_composite_indexes` — the MULTI-column half of the same index set
#
# `_sqlite_single_column_indexed_columns` above ends at `HAVING COUNT(*) = 1`, so every
# multi-column index was invisible: `inspectdb` on a live database silently dropped them and PormG
# had no primitive to express one anyway. This reader is that function with the arity inverted, and
# the two must PARTITION the set — an index feeding both `db_index` and a `Models.Index` would be
# created twice and diffed against itself.
#
# The two things this reader needs that its single-column sibling does not are asserted explicitly:
# column ORDER (an index over (b, a) is not the index over (a, b)) and dropping an expression index
# whole rather than declaring its remaining columns as if they were the index.
# ─────────────────────────────────────────────────────────────────────────────
@testset "_sqlite_composite_indexes (#347)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "compositeidx.sqlite"); pool_size = 1)
    try
      # One of every shape again, but now judged from the other side of the arity split:
      #   ix_ba   → composite CREATE INDEX     (origin 'c', unique 0, 2 cols)  ← the ONLY Index
      #   ix_solo → single-column CREATE INDEX (origin 'c', unique 0, 1 col)   → db_index
      #   ux_cd   → composite CREATE UNIQUE    (unique 1)                      → UniqueConstraint
      #   ix_part → composite partial index    (partial 1)
      #   ix_expr → composite expression index (a member has no attribute name)
      #   ix_desc → composite DESC index       (a member has desc = 1)
      #   ix_coll → composite COLLATE NOCASE   (a member has a non-BINARY collation)
      fetch(pool, """CREATE TABLE t347 (
        id INTEGER PRIMARY KEY, a TEXT, b TEXT, c TEXT, d TEXT, solo TEXT, uc TEXT UNIQUE);""")
      fetch(pool, "CREATE INDEX ix_ba ON t347(b, a);")
      fetch(pool, "CREATE INDEX ix_solo ON t347(solo);")
      fetch(pool, "CREATE UNIQUE INDEX ux_cd ON t347(c, d);")
      fetch(pool, "CREATE INDEX ix_part ON t347(c, d) WHERE c IS NOT NULL;")
      fetch(pool, "CREATE INDEX ix_expr ON t347(lower(c), d);")
      fetch(pool, "CREATE INDEX ix_desc ON t347(c DESC, d);")
      fetch(pool, "CREATE INDEX ix_coll ON t347(c COLLATE NOCASE, d);")

      idx = _sqlite_composite_indexes(pool, :t347)
      names = [p.first for p in idx]

      @test names == ["ix_ba"]                    # exactly one survives every filter
      # Column ORDER is the index's identity, and it is DECLARED order, not table order. `b` comes
      # after `a` in the table, so a reader aggregating by attribute would return ["a","b"] here.
      @test idx[1].second == ["b", "a"]

      # Spelled out individually so a failure names the filter that broke:
      @test !("ix_solo" in names)   # arity 1 is db_index — read by the sibling above, not here
      @test !("ux_cd" in names)     # drop `il."unique" = 0` and a composite UniqueConstraint (#19)
                                    #   leaks in and would be re-declared as a plain index
      @test !("ix_part" in names)   # drop `il.partial = 0` and a partial index leaks in; PormG
                                    #   cannot declare one, so reading it would be permanent churn
      @test !("ix_expr" in names)   # an expression member has a NULL name — emitting the remaining
                                    #   columns would declare a DIFFERENT index (functional: #29)
      # The two shapes `pragma_index_info` cannot even see, which is why this reader uses `xinfo`.
      # Both would otherwise read back as a plain ascending BINARY index and regenerate as one — the
      # reinterpretation the Django importer already refuses on `Index(fields=["-year"])`.
      @test !("ix_desc" in names)   # a DESC key: PormG indexes carry no per-column order
      @test !("ix_coll" in names)   # COLLATE NOCASE: a different comparison, so a different index
      @test !any(startswith(n, "sqlite_autoindex") for n in names)  # the UNIQUE column's auto-index

      # An unknown table yields an empty vector rather than throwing — convert_schema_to_models calls
      # this per table and must survive a race with a concurrent DROP.
      @test _sqlite_composite_indexes(pool, :nonexistent) == Pair{String, Vector{String}}[]

      # END TO END: the vector is only useful if convertSQLToModel attaches it. Without this the
      # whole reader could be inert and every assertion above would still pass.
      m = convertSQLToModel(pool, "t347")
      @test haskey(m.cache, "composite_indexes")
      ixs = m.cache["composite_indexes"]["indexes"]
      @test length(ixs) == 1
      @test ixs[1].fields == ["b", "a"]
      @test ixs[1].name == "ix_ba"                # the LIVE name, so a re-migration reproduces it

      # The two readers partition: `solo` is db_index and is NOT also a composite index, while the
      # composite members `a`/`b` are NOT marked db_index. Either overlap is a churn loop.
      @test m.fields["solo"].db_index
      @test !m.fields["a"].db_index
      @test !m.fields["b"].db_index
      @test m.cache["index"]["solo"] == "ix_solo" # and both cache keys coexist — one must not
                                                  #   overwrite the other on the way in

      # A table with no composite index carries no entry at all, so nothing changes for the
      # overwhelmingly common case.
      fetch(pool, "CREATE TABLE t347_plain (id INTEGER PRIMARY KEY, x TEXT);")
      @test !haskey(convertSQLToModel(pool, "t347_plain").cache, "composite_indexes")
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# EXPRESSION AND PARTIAL INDEXES — the deletion path SQLite refused (#519)
#
# `ALTER TABLE … DROP COLUMN` on SQLite is refused for a column ANY index references. PormG decided
# "is this column indexed?" through `get_constraints_index`, whose SQLite half joins
# `pragma_index_info` and matches `ii.name = ?` — and `pragma_index_info` reports `name = NULL` for an
# EXPRESSION member (an expression has no column name to give) and never lists a PARTIAL index's
# `WHERE` columns. So a column covered only by `CREATE INDEX ix ON t(lower("a"))` read as unindexed,
# nothing was pre-dropped, and the plain `DROP COLUMN` failed with *"error in index ix after drop
# column: no such column: a"*.
#
# The fix is two-sided, and BOTH sides are required — fixing only the planner produces a rebuild that
# then re-emits the very index that forced it:
#   * `_sqlite_indexes_referencing_column` routes the deletion through the table rebuild (planner);
#   * `get_secondary_index_ddls` stops re-creating an index that references a dropped column, and
#     warns by name when it drops one PormG could not have created.
#
# Detection reads the index's DDL from `sqlite_master`, which the #515 rule constrains: no unanchored
# substring, no `LIKE`. It is an identifier-aware tokenizer whose candidates are then confirmed
# against `pragma_table_info`, so the DDL narrows and the CATALOG decides. The testset at the bottom
# is the one that enforces that — every other assertion here would also pass an `occursin` hack.
#
# Hermetic: a real temp SQLite file, no integration fixture. This is the issue's own repro.
# ─────────────────────────────────────────────────────────────────────────────

# Plan `declared` against whatever `pool` actually holds, using the REAL introspected live model
# rather than a hand-built one — the point of these tests is what the planner does with a live
# catalog it read itself. `get_migration_plan` takes the LIVE models positionally and the DECLARED
# ones in `current_schema`, which is the planner's own (deliberately confusing) argument order.
function _ei_plan(pool, declared::PormGModel, table::Symbol)
  settings = PormG.Configuration.Settings()
  settings.change_db = true
  live = PormGModel[m for m in PormG.Migrations.convert_schema_to_models(pool)
                    if lowercase(string(m.name)) == lowercase(string(table))]
  @assert length(live) == 1 "expected exactly one live model for $(table), got $(length(live))"
  current_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
    table => Dict{Symbol, Union{Bool, PormGModel}}(:model => declared, :exist => false))
  return PormG.Migrations.get_migration_plan(live, current_schema, pool, settings;
                                             interactive = false)
end

_ei_steps(plan, table::Symbol) = haskey(plan, table) ? collect(keys(plan[table])) : String[]

# Apply a plan the way `migrate` does — through `_order_statements`, NOT by replaying the plan dict's
# own insertion order. On SQLite the rebuild entry is relocated to the end of the table's plan and the
# index statements are deferred behind it; replaying the raw order would execute a rebuild before the
# renames it depends on and fail for a reason that has nothing to do with the test.
function _ei_apply!(pool, plan, table::Symbol)
  haskey(plan, table) || return nothing
  ordered, _ = PormG.Migrations._order_statements([plan[table]])
  for sql in ordered
    for stmt in split(sql, ";")
      st = strip(stmt)
      isempty(st) && continue
      fetch(pool, st * ";")
    end
  end
  return nothing
end

_ei_index_names(pool, table::String) =
  Set(String[string(r.name) for r in eachrow(
        fetch(pool, "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = '$(table)' AND sql IS NOT NULL") |> DataFrame)])

_ei_columns(pool, table::String) =
  Set(String[string(r.name) for r in eachrow(
        fetch(pool, "SELECT name FROM pragma_table_info('$(table)')") |> DataFrame)])

# ─────────────────────────────────────────────────────────────────────────────
# #519 (a): the issue's repro, end to end against a real SQLite file
# A column covered ONLY by an expression index is deleted. Before #519 the planner emitted a plain
# `DROP COLUMN` (because `get_constraints_index` could not see the index) and SQLite refused it. It
# must now route through the table rebuild and EXECUTE — the assertion that fails on a string-level
# fix is the `_ei_apply!` call, not the plan shape.
# ─────────────────────────────────────────────────────────────────────────────
@testset "expression index blocks DROP COLUMN, so deletion rebuilds (#519)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "expr519.sqlite"); pool_size = 1)
    try
      # The issue's fixture, plus a second expression index on the column that SURVIVES — the
      # negative control that separates "the filter works" from "the filter drops everything".
      fetch(pool, """CREATE TABLE "t" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "a" TEXT, "b" TEXT);""")
      fetch(pool, """CREATE INDEX "t_a_lower_idx" ON "t" (lower("a"));""")
      fetch(pool, """CREATE INDEX "t_b_lower_idx" ON "t" (lower("b"));""")
      fetch(pool, """INSERT INTO "t" ("a", "b") VALUES ('keep-a', 'keep-b');""")

      # The blind spot itself, pinned: `get_constraints_index` still cannot see the expression index.
      # That is CORRECT after #519 — it answers "may PormG drop this index?", not "is the column
      # blocked?" — and pinning it here is what proves the fix did not come from widening that
      # function (which would have destroyed constraint-backed indexes; see #515).
      @test get_constraints_index(pool, :t, "a") === nothing

      # …while the new probe finds it, and does NOT find the index on the other column.
      @test _sqlite_indexes_referencing_column(pool, "t", "a") == ["t_a_lower_idx"]
      @test _sqlite_indexes_referencing_column(pool, "t", "b") == ["t_b_lower_idx"]

      # Declared model drops "a". The rebuild is keyed "Alter table: t"; a plain deletion would be
      # "Remove field: a" plus possibly "Remove index on a".
      declared = PormG.Models.Model("t"; id = PormG.Models.IDField(),
                                    b = PormG.Models.CharField(null = true))
      plan = _ei_plan(pool, declared, :t)
      steps = _ei_steps(plan, :t)
      @test "Alter table: t" in steps
      @test !any(st -> startswith(st, "Remove field:"), steps)

      # THE GATE: it executes. Before #519 the plan was `DROP COLUMN "a"` and SQLite raised.
      _ei_apply!(pool, plan, :t)

      @test !("a" in _ei_columns(pool, "t"))
      @test "b" in _ei_columns(pool, "t")
      # Data survived the rebuild.
      rows = fetch(pool, """SELECT "b" FROM "t";""") |> DataFrame
      @test nrow(rows) == 1
      @test rows[1, :b] == "keep-b"

      # (b) The expression index on the DELETED column is gone with the rebuild — not re-emitted,
      #     which is what used to make the rebuild itself fail with "no such column".
      # (c) The expression index on a DIFFERENT column SURVIVED the rebuild.
      live_idx = _ei_index_names(pool, "t")
      @test !("t_a_lower_idx" in live_idx)
      @test "t_b_lower_idx" in live_idx
    finally
      # Release the SQLite handle so mktempdir can delete the temp DB on Windows (WAL keeps it open).
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #519 (d): a PARTIAL index's WHERE column is a reference too
# `CREATE INDEX ix ON t(b) WHERE a > 0` lists only `b` in `pragma_index_info`, yet dropping `a`
# breaks it exactly as badly. Same route, same rebuild, and the index must not come back.
# ─────────────────────────────────────────────────────────────────────────────
@testset "partial index WHERE column blocks DROP COLUMN (#519)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "partial519.sqlite"); pool_size = 1)
    try
      fetch(pool, """CREATE TABLE "t" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "a" INTEGER, "b" TEXT);""")
      fetch(pool, """CREATE INDEX "t_b_where_a_idx" ON "t" ("b") WHERE "a" > 0;""")

      # `pragma_index_info` reports the index as covering `b` alone — the exact blindness.
      members = fetch(pool, """SELECT name FROM pragma_index_info('t_b_where_a_idx')""") |> DataFrame
      @test Set(String[string(c) for c in members.name if c !== missing]) == Set(["b"])
      # …while the DDL-aware reader sees both.
      refs = _sqlite_index_referenced_columns(pool, "t", "t_b_where_a_idx",
        """CREATE INDEX "t_b_where_a_idx" ON "t" ("b") WHERE "a" > 0""")
      @test refs == Set(["a", "b"])

      @test _sqlite_indexes_referencing_column(pool, "t", "a") == ["t_b_where_a_idx"]

      declared = PormG.Models.Model("t"; id = PormG.Models.IDField(),
                                    b = PormG.Models.CharField(null = true))
      plan = _ei_plan(pool, declared, :t)
      @test "Alter table: t" in _ei_steps(plan, :t)
      _ei_apply!(pool, plan, :t)

      @test !("a" in _ei_columns(pool, "t"))
      @test !("t_b_where_a_idx" in _ei_index_names(pool, "t"))
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #519 (e): nothing is dropped in silence
# The rebuild drops an expression/partial index that no model declaration can express, so the
# operator has to hear about it by name. A PLAIN column index is `db_index` / `Models.Index`, which
# the declared model re-creates on its own — warning there would be noise on every field deletion,
# so this asserts both halves: the unmodellable one warns, the plain one does not.
# ─────────────────────────────────────────────────────────────────────────────
@testset "dropping an unmodellable index warns by name (#519)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "warn519.sqlite"); pool_size = 1)
    try
      fetch(pool, """CREATE TABLE "t" ("a" TEXT, "b" TEXT, "c" TEXT);""")
      fetch(pool, """CREATE INDEX "t_expr_idx" ON "t" (lower("a"));""")   # unmodellable
      fetch(pool, """CREATE INDEX "t_plain_idx" ON "t" ("b");""")         # PormG's own shape

      # Dropping "a" loses the expression index: a warning naming it, and the DDL is not re-emitted.
      # `collect_test_logs` captures the records AND returns the call's value, so one call answers
      # both halves — and the warning does not leak into the test output.
      records, ddls = Test.collect_test_logs() do
        get_secondary_index_ddls(pool, "t"; surviving_columns = Set(["b", "c"]))
      end
      @test !any(d -> occursin("t_expr_idx", d), ddls)
      @test any(d -> occursin("t_plain_idx", d), ddls)

      warns = [r for r in records if r.level == Logging.Warn]
      @test length(warns) == 1
      # It names the index, so an operator can re-create it by hand.
      @test occursin("t_expr_idx", string(warns[1].kwargs[:index]))
      @test "a" in warns[1].kwargs[:dropped_columns]

      # Dropping "b" loses only the PLAIN index, which the declared model re-creates — no warning.
      records_plain, _ = Test.collect_test_logs() do
        get_secondary_index_ddls(pool, "t"; surviving_columns = Set(["a", "c"]))
      end
      @test isempty([r for r in records_plain if r.level == Logging.Warn])

      # Classification, directly: pragma explains the plain index's columns and not the expression's.
      @test _sqlite_index_is_unmodellable("""CREATE INDEX "t_expr_idx" ON "t" (lower("a"))""",
                                          Set{String}(), Set(["a"]))
      @test !_sqlite_index_is_unmodellable("""CREATE INDEX "t_plain_idx" ON "t" ("b")""",
                                           Set(["b"]), Set(["b"]))
      # A partial index whose WHERE names only a plain member is still unmodellable — the difference
      # test alone would miss it, so the WHERE token is checked separately.
      @test _sqlite_index_is_unmodellable("""CREATE INDEX "ix" ON "t" ("a") WHERE "a" > 0""",
                                          Set(["a"]), Set(["a"]))
      # COLLATE and a sort direction are unmodellable too: no PormG renderer emits either, so a
      # rebuild cannot bring them back and their loss must not be silent. Django's
      # `Index(fields=['-name'])` produces the DESC form, so an imported schema can carry one.
      @test _sqlite_index_is_unmodellable("""CREATE INDEX "ix" ON "t" ("a" COLLATE NOCASE)""",
                                          Set(["a"]), Set(["a"]))
      @test _sqlite_index_is_unmodellable("""CREATE INDEX "ix" ON "t" ("a" DESC)""",
                                          Set(["a"]), Set(["a"]))
      # …but a QUOTED column named `desc` is an ordinary plain index, not a sort direction.
      @test !_sqlite_index_is_unmodellable("""CREATE INDEX "ix" ON "t" ("desc")""",
                                           Set(["desc"]), Set(["desc"]))
      # A plain CREATE UNIQUE INDEX is modellable: PormG renders those from `unique_together` and for
      # M2M join tables, so one referencing a dropped column is intent the declared model dropped too.
      @test !_sqlite_index_is_unmodellable("""CREATE UNIQUE INDEX "uq" ON "t" ("a", "b")""",
                                           Set(["a", "b"]), Set(["a", "b"]))
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #519 (e2): TWO plain indexes on one column — the sibling defect the wide rule closes
# `get_constraints_index` returns `result[1, …]`, a SINGLE name, so the old cheap path pre-dropped one
# index and then issued `DROP COLUMN` with the second still standing. SQLite refused it. That has
# nothing to do with expression indexes, and it is why #519's fix routes on "ANY index references this
# column" rather than on "an index PormG could not see".
#
# The first half of this testset REPRODUCES the old failure directly against SQLite — pre-drop the one
# name the lookup gives, then try the drop — so the justification in `planner.jl`'s comment is
# executed rather than merely asserted. The second half is the fix: the new probe returns BOTH indexes,
# so the planner routes the deletion to the rebuild and the column goes with the table.
# ─────────────────────────────────────────────────────────────────────────────
@testset "two plain indexes on one column also blocked DROP COLUMN (#519)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "twoidx519.sqlite"); pool_size = 1)
    try
      fetch(pool, """CREATE TABLE "t" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "a" TEXT, "b" TEXT);""")
      fetch(pool, """CREATE INDEX "t_a_one" ON "t" ("a");""")
      fetch(pool, """CREATE INDEX "t_a_two" ON "t" ("a");""")

      # The lookup names exactly one of the two — the shape that made the pre-drop insufficient.
      named = get_constraints_index(pool, :t, "a")
      @test named !== nothing
      @test named in ("t_a_one", "t_a_two")

      # …while the new probe returns both, in name order.
      @test _sqlite_indexes_referencing_column(pool, "t", "a") == ["t_a_one", "t_a_two"]

      # THE OLD PATH, replayed: pre-drop the single named index, then `DROP COLUMN`. SQLite refuses,
      # naming the index that was left behind. This is the assertion that makes the wide rule's
      # justification a fact rather than a story.
      fetch(pool, """DROP INDEX IF EXISTS "$(named)";""")
      refused = false
      msg = ""
      try
        fetch(pool, """ALTER TABLE "t" DROP COLUMN "a";""")
      catch e
        refused = true
        msg = sprint(showerror, e)
      end
      @test refused
      # It names the SURVIVING index, not the pre-dropped one — proof the refusal is about the second
      # index rather than about anything else going wrong.
      survivor = named == "t_a_one" ? "t_a_two" : "t_a_one"
      @test occursin(survivor, msg)

      # And the fix: with both indexes present the planner takes the rebuild, which succeeds.
      fetch(pool, """CREATE INDEX "$(named)" ON "t" ("a");""")
      declared = PormG.Models.Model("t"; id = PormG.Models.IDField(),
                                    b = PormG.Models.CharField(null = true))
      plan = _ei_plan(pool, declared, :t)
      @test "Alter table: t" in _ei_steps(plan, :t)
      _ei_apply!(pool, plan, :t)
      @test !("a" in _ei_columns(pool, "t"))
      # Both indexes went with the table; neither was re-created against a column that is gone.
      live = _ei_index_names(pool, "t")
      @test !("t_a_one" in live)
      @test !("t_a_two" in live)
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #519 (e3): SQL syntax must not fabricate a column reference — FOUND IN REVIEW
# The first version of this change treated every bare word in the index's argument region as a
# candidate column, filtered only by "does the table have a column of that name?". A table with a
# column named `desc` (ordinary in a legacy schema) plus an ordinary DESCENDING index on a DIFFERENT
# column was enough to break it: `CREATE INDEX ix ON t("a" DESC)` read as referencing `a` AND `desc`,
# so deleting `desc` dropped an index on the surviving column `a` — silently, and reported as an
# expression index. That is the one failure direction that must not happen, because the loud one
# (re-emitting an index over a dropped column) announces itself.
#
# Fixed by having the tokenizer report whether an identifier was QUOTED: a column whose name is a
# reserved word can only be referenced quoted, and the syntax is never quoted. This testset is the
# END-TO-END half — the survival of the other column's index through a real rebuild. The token-level
# half is in the identifier-aware testset below.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a column named like SQL syntax does not steal another column's index (#519)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "syntax519.sqlite"); pool_size = 1)
    try
      # `desc` and `nocase` are real columns AND words that appear as syntax in an index definition.
      fetch(pool, """CREATE TABLE "t" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "a" TEXT, "desc" TEXT, "nocase" TEXT);""")
      fetch(pool, """CREATE INDEX "ix_a_desc" ON "t" ("a" DESC);""")
      fetch(pool, """CREATE INDEX "ix_a_coll" ON "t" ("a" COLLATE NOCASE);""")
      fetch(pool, """INSERT INTO "t" ("a", "desc", "nocase") VALUES ('keep', 'gone', 'gone2');""")

      # Neither index references `desc` or `nocase` — the words in them are syntax, not columns.
      @test isempty(_sqlite_indexes_referencing_column(pool, "t", "desc"))
      @test isempty(_sqlite_indexes_referencing_column(pool, "t", "nocase"))
      # …and both DO reference `a`, so the fix did not simply stop matching.
      @test _sqlite_indexes_referencing_column(pool, "t", "a") == ["ix_a_coll", "ix_a_desc"]

      # Delete both syntax-named columns. `a` and its two indexes must come through untouched.
      #
      # `db_index = true` on the declared side is REQUIRED and not incidental: introspection reads a
      # single-column index — DESC and COLLATE ones included — back as `db_index`, so a declared model
      # without it is genuinely asking PormG to remove the index, and `index_actions` would queue that
      # drop after the rebuild. Declaring it keeps this testset about the rebuild's index preservation
      # rather than about an index the model asked to lose.
      declared = PormG.Models.Model("t"; id = PormG.Models.IDField(),
                                    a = PormG.Models.CharField(null = true, db_index = true))
      plan = _ei_plan(pool, declared, :t)
      _ei_apply!(pool, plan, :t)

      @test !("desc" in _ei_columns(pool, "t"))
      @test !("nocase" in _ei_columns(pool, "t"))
      @test "a" in _ei_columns(pool, "t")

      # THE ASSERTION THE DEFECT FAILED: both indexes on the surviving column are still there, and
      # still carry their modifiers — a rebuild that dropped them would have lost DESC/COLLATE for
      # good, since no model declaration can re-create either.
      live = _ei_index_names(pool, "t")
      @test "ix_a_desc" in live
      @test "ix_a_coll" in live
      ddl = fetch(pool, "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'ix_a_desc'") |> DataFrame
      @test occursin("DESC", string(ddl[1, :sql]))

      # Data survived, and the deleted columns' data went with them.
      rows = fetch(pool, """SELECT "a" FROM "t";""") |> DataFrame
      @test nrow(rows) == 1
      @test rows[1, :a] == "keep"
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #519 (e4): a mixed-case table name resolves the SAME way in both halves — FOUND IN RE-REVIEW
# The two halves of #519 have to agree about which table they are talking about, and they get the name
# from DIFFERENT places: the planner's key reaches `_sqlite_indexes_referencing_column`, while
# `model_table_name(current_model)` reaches `get_secondary_index_ddls`. SQLite resolves a table name
# case-insensitively, but `sqlite_master.tbl_name` is BINARY-collated, so a literal comparison is
# case-SENSITIVE.
#
# Making only the probe insensitive was strictly worse than leaving both blind, and that is what this
# testset pins. Blind + blind agreed: the deletion took the `DROP COLUMN` path and SQLite refused it
# loudly. Insensitive probe + sensitive snapshot meant "route this to a rebuild, and re-create NONE of
# the table's indexes" — every index silently lost, including ones on columns nobody touched. That is
# the #82 class the filter exists to prevent, converted from a loud failure into a silent one.
# ─────────────────────────────────────────────────────────────────────────────
@testset "both halves resolve a mixed-case table name identically (#519/#57)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "case519.sqlite"); pool_size = 1)
    try
      # Created mixed-case, queried lower-case — the shape an explicit `db_table` or a Django import
      # produces (#57 covers mixed-case columns; this is the table name).
      fetch(pool, """CREATE TABLE "MyTab" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "a" TEXT, "b" TEXT);""")
      fetch(pool, """CREATE INDEX "ix_MyTab_a" ON "MyTab" ("a");""")
      fetch(pool, """CREATE INDEX "ix_MyTab_b" ON "MyTab" ("b");""")

      # The probe finds the index under the other casing…
      @test _sqlite_indexes_referencing_column(pool, "mytab", "b") == ["ix_MyTab_b"]
      # …and so does the neighbour in the same planner disjunct, which goes through `PRAGMA
      # index_list` and was always case-insensitive. All three name lookups must agree.
      @test _sqlite_column_is_unique(pool, "mytab", "b") == false

      # THE REGRESSION GUARD: the DDL snapshot must see the table too. If this returns `String[]` the
      # rebuild re-creates nothing, and the index on the untouched column `a` is lost in silence.
      kept = get_secondary_index_ddls(pool, "mytab"; surviving_columns = Set(["id", "a"]))
      @test length(kept) == 1
      @test occursin("ix_MyTab_a", kept[1])
      # Unfiltered, both come back — so the assertion above is about the FILTER, not about the query
      # finding nothing at all.
      @test length(get_secondary_index_ddls(pool, "mytab")) == 2
    finally
      close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# #519 (f): the identifier match is identifier-aware, per the #515 rule
# THIS is the mutation gate. Every assertion above would also pass an unanchored
# `occursin(column, index_ddl)`, which is precisely what #515 removed from the PostgreSQL side. These
# cases fail it: a column name inside a STRING LITERAL, a FUNCTION whose name equals a column, a
# longer identifier that merely CONTAINS the name, and the index's own name or its table's name.
#
# Asserted against a real table so the catalog confirmation is in the loop — a candidate token only
# counts when `pragma_table_info` says the column exists.
# ─────────────────────────────────────────────────────────────────────────────
@testset "index column detection is identifier-aware, not substring (#519/#515)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "tok519.sqlite"); pool_size = 1)
    try
      # Columns chosen to trap a substring match: "a" is a prefix of "aa" and "a_b"; "lower" is also
      # a function name; "t" is also the table's name; "x" would be produced by misreading a blob
      # literal `x'…'`; "desc"/"nocase"/"where" are SQL syntax in this very position.
      fetch(pool, """CREATE TABLE "t" ("a" TEXT, "aa" TEXT, "a_b" TEXT, "b" TEXT, "lower" TEXT, "t" TEXT, "x" TEXT, "desc" TEXT, "nocase" TEXT, "where" TEXT);""")

      refs(idx, sql) = _sqlite_index_referenced_columns(pool, "t", idx, sql)
      # No such index exists, so `pragma_index_info` contributes nothing and every answer below comes
      # from the DDL reader alone — which is exactly the half under test.
      @test isempty(refs("nope", nothing))

      # A string literal is not a reference. `'a'` must not make the index depend on column "a".
      @test refs("i1", """CREATE INDEX "i1" ON "t" ("b") WHERE "b" = 'a'""") == Set(["b"])
      # …including a doubled-quote escape inside the literal.
      @test refs("i1b", """CREATE INDEX "i1b" ON "t" ("b") WHERE "b" = 'it''s a'""") == Set(["b"])

      # A function call is not a column reference — even when a column of that name exists.
      @test refs("i2", """CREATE INDEX "i2" ON "t" (lower("a"))""") == Set(["a"])
      # …and the column named `lower` IS found when it is used as a column rather than called.
      @test refs("i3", """CREATE INDEX "i3" ON "t" ("lower")""") == Set(["lower"])

      # A longer identifier that contains the name is a different column, not this one.
      @test refs("i4", """CREATE INDEX "i4" ON "t" ("aa")""") == Set(["aa"])
      @test refs("i5", """CREATE INDEX "i5" ON "t" ("a_b")""") == Set(["a_b"])
      # Bare (unquoted) spelling too — this is what a hand-written index usually looks like.
      @test refs("i6", "CREATE INDEX i6 ON t(aa)") == Set(["aa"])

      # The INDEX name and the TABLE name are outside the scanned region, structurally. Both are "a"
      # here, and the only reference is "b".
      @test refs("a", """CREATE INDEX "a" ON "t" ("b")""") == Set(["b"])
      # A column that shares the table's name is still found when it is really referenced.
      @test refs("i7", """CREATE INDEX "i7" ON "t" ("t")""") == Set(["t"])

      # SQLite's other two quoted-identifier spellings.
      @test refs("i8", """CREATE INDEX "i8" ON "t" ([a])""") == Set(["a"])
      @test refs("i9", "CREATE INDEX i9 ON t(`a`)") == Set(["a"])

      # Identifiers are ASCII-case-insensitive in SQLite; the LIVE spelling comes back.
      @test refs("i10", """CREATE INDEX "i10" ON "t" (UPPER("A"))""") == Set(["a"])

      # A comment is not DDL.
      @test refs("i11", """CREATE INDEX "i11" ON "t" ("b") /* "a" */""") == Set(["b"])
      @test refs("i12", "CREATE INDEX i12 ON t(b) -- a\n") == Set(["b"])

      # A blob literal must not read as the identifier `x` — load-bearing only because the fixture
      # really has a column named "x", so a missing blob branch would show up as a false reference.
      @test refs("i13", """CREATE INDEX "i13" ON "t" ("b") WHERE "b" != x'00'""") == Set(["b"])

      # ── SQL SYNTAX is not a column reference, even when a column of that name exists ──
      # This is the direction that MATTERS: reading `DESC` as the column "desc" made a rebuild drop
      # `i14`, an index on the surviving column "a", and report it as an expression index. An index
      # lost on a column nobody touched, silently.
      @test refs("i14", """CREATE INDEX "i14" ON "t" ("a" DESC)""") == Set(["a"])
      @test refs("i15", """CREATE INDEX "i15" ON "t" ("a" ASC, "b" DESC)""") == Set(["a", "b"])
      # A COLLATE name is not a column either — consumed positionally, because a user-defined
      # collation can be called anything, including the name of a real column.
      @test refs("i16", """CREATE INDEX "i16" ON "t" ("a" COLLATE NOCASE)""") == Set(["a"])
      # …and the predicate keywords.
      @test refs("i17", """CREATE INDEX "i17" ON "t" ("a") WHERE "b" IS NOT NULL AND "a" LIKE 'z%'""") ==
            Set(["a", "b"])
      # The QUOTED spellings of those same words ARE columns — that is the whole discriminator, and
      # it is why the tokenizer reports quoting rather than matching on the word alone.
      @test refs("i18", """CREATE INDEX "i18" ON "t" ("desc")""") == Set(["desc"])
      @test refs("i19", """CREATE INDEX "i19" ON "t" ("nocase", "where")""") == Set(["nocase", "where"])
      # …including a quoted keyword used together with the bare one it collides with.
      @test refs("i20", """CREATE INDEX "i20" ON "t" ("desc" DESC)""") == Set(["desc"])

      # And the region boundary itself: everything before the first `(` is excluded, including a
      # parenthesis hiding inside a quoted index name.
      @test _sqlite_index_argument_region("""CREATE INDEX "i(x" ON "t" ("b")""") == """("b")"""

      # ── The token SHAPE itself ──
      # `quoted` is the load-bearing discriminator and both call sites destructure the tuple
      # POSITIONALLY, so inserting a flag in the middle would silently change their meaning. Pin it.
      @test _sqlite_identifier_tokens("""("a" DESC)""") == [("a", false, true), ("DESC", false, false)]
      @test _sqlite_identifier_tokens("""(lower("a"))""") == [("lower", true, false), ("a", false, true)]

      # ── COLLATE consumes exactly one following identifier ──
      # SQLite's grammar is `COLLATE <collation-name>`, one identifier, so the rule is positional
      # rather than a name list — a user-defined collation can be called anything, including the name
      # of a real column. These are the spellings where positional consumption could have been wrong.
      @test refs("i21", """CREATE INDEX "i21" ON "t" ("a" COLLATE "nocase")""") == Set(["a"])
      @test refs("i22", """CREATE INDEX "i22" ON "t" ("a" COLLATE NOCASE DESC)""") == Set(["a"])
      @test refs("i23", """CREATE INDEX "i23" ON "t" ("a" COLLATE [nocase])""") == Set(["a"])
      # A COLLATE inside a predicate must not swallow the column after it.
      @test refs("i24", """CREATE INDEX "i24" ON "t" ("a") WHERE "b" COLLATE NOCASE = 'x'""") ==
            Set(["a", "b"])
      # A trailing COLLATE with nothing after it must not throw.
      @test refs("i25", """CREATE INDEX "i25" ON "t" ("a" COLLATE""") == Set(["a"])
      # …and a QUOTED `collate` is a column named `collate`, not the keyword. (No such column here, so
      # the catalog filters it — the point is that it does not consume the token after it.)
      @test refs("i26", """CREATE INDEX "i26" ON "t" ("collate", "a")""") == Set(["a"])
    finally
      close_pool!(pool)
    end
  end
end
