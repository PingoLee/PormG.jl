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
import PormG.Migrations: get_secondary_index_ddls, _sqlite_column_is_unique,
                         _sqlite_single_column_unique_columns,
                         _sqlite_single_column_indexed_columns, _sqlite_composite_indexes,
                         convertSQLToModel

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
