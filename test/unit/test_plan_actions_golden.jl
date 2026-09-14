"""
Plan actions derive from the typed delta (#507 phase 2).

Phase 1 made `makemigrations` decide *changed / unchanged* from a canonical column IR. Phase 2 makes
every plan ACTION derive from the same typed delta, so no action site re-inspects the two
`PormGField` structs to re-decide what the compiler already decided. This file is the guard on that,
in three parts:

1. **The golden plan corpus.** 38 (declared, live) column pairs driven end to end through
   `get_migration_plan` on both engines — 76 rendered plans, pinned statement for statement. 32 of
   those pairs were captured on the BASE COMMIT before a line of phase 2 was written, so this file
   is evidence that the refactor did not move plan text rather than a snapshot of whatever it
   happens to produce now; **7 of those 64 plans legitimately changed** and carry their before AND
   after with the reason (see `Deliberate differences` below). 4 more pairs were added after review,
   to cover a hazard nothing here could see — see `Post-review coverage` — and 2 for #523, which no
   pair reached at all.
2. **Renderer coverage.** Every slot `column_delta` can emit reaches a statement in
   `Dialect.alter_field`, or is the one documented exception. Walked from `COLUMN_DELTA_SLOTS`
   itself, and asserted by CALLING the renderer — phase 1's version of this test compared symbols
   against a hand-transcribed copy of the renderer's allowlist and passed while the call raised.
3. **The single foreign-key decision.** `_fk_constraint_action` over specs: all four outcomes, the
   deletion path, and the shapes that used to raise.

Hermetic: mock connections on both engines, no database. `get_secondary_index_ddls` answers
`String[]` from an empty-`DataFrame` `fetch`, which is a truthful "this table has no secondary
indexes" and is what lets the SQLite rebuild render in full without a file.

The constraint-name mocks are **column-aware**, and that is load-bearing rather than fussy: they
answer for `col` and return `nothing` for anything else, which is what a real catalog does at plan
time. The first version answered for every column, and it hid a defect in this very change — see
`Post-review coverage`. A mock that cannot answer "no" cannot catch a wrong question.

    julia --project=. test/unit/test_plan_actions_golden.jl
"""

using Test
using Logging
using DataFrames
using PormG
using PormG.Models
using PormG.Migrations
import PormG: PormGModel, PormGPostgres, PormGSQLite
import PormG: ColumnSpec, ColumnDelta, ColumnIdentity, ForeignKeyRef, CanonicalType,
              CInt32, CInt64, CText, CVarChar, CUnsupported,
              NoDefault, LiteralDefault, ExpressionDefault,
              NonNegativeCheck, ByteLengthCheck, CheckKind,
              COLUMN_DELTA_SLOTS, COLUMN_DELTA_COMPARATORS, column_delta
# The reordering testset opens a real (temporary) SQLite file, so it needs the weakdep extension.
# `runtests.jl` loads it for the whole suite; this guard is what makes the file runnable on its own.
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG.ConnectionPool: fetch, SQLiteConnectionPool
import PormG: Dialect
import PormG.Migrations: _fk_constraint_action, column_spec

# -- Mock connections ----------------------------------------------------------
# Suffixed names: `runtests.jl` includes every unit file into ONE module, so a bare `MockPostgres`
# silently redefines a sibling's.
struct GoldenMockPg507 <: PormGPostgres end
struct GoldenMockSl507 <: PormGSQLite end
const GPG507 = GoldenMockPg507()
const GSL507 = GoldenMockSl507()

# The four constraint-name lookups `alter_field`'s DROP branches ask the catalog for.
PormG.get_constraints_pk(::GoldenMockPg507, t::String, f::String) = f == "col" ? "child_t_pkey" : nothing
PormG.get_constraints_unique(::GoldenMockPg507, t::String, f::String) = f == "col" ? "child_t_col_key" : nothing
PormG.get_constraints_check(::GoldenMockPg507, t::String, f::String) = f == "col" ? "child_t_col_check" : nothing
PormG.get_constraints_byte_length_check(::GoldenMockPg507, t::String, f::String) = f == "col" ? "child_t_col_bytes" : nothing
PormG.backend_sqlite_version(::GoldenMockSl507) = 3045000

const GOLDEN_LIVE_FK_CONSTRAINT = "child_t_col_0ld00001_fk"

# Column-aware for the same reason the four lookups above are: `get_constraints_fk` is PARAMETERIZED
# (#498), so the column arrives in `params` rather than in the SQL text, and answering for every
# column would let a wrong lookup key pass unnoticed here too. It answers for `col` — the column the
# live table has — which is what makes the rename goldens assert the PRE-rename key rather than
# merely some key.
function fetch(connection::GoldenMockPg507, sql::String;
               conn = nothing, params = nothing, ignore_tx::Bool = false)
  if occursin("constraint_type = 'FOREIGN KEY'", sql)
    params !== nothing && length(params) == 2 && params[2] == "col" &&
      return DataFrame(constraint_name = [GOLDEN_LIVE_FK_CONSTRAINT])
    return DataFrame()
  end
  return DataFrame()
end

function fetch(connection::GoldenMockSl507, sql::String;
               conn = nothing, params = nothing, ignore_tx::Bool = false)
  return DataFrame()
end

# -- Fixtures ------------------------------------------------------------------
_g_parent()       = Models.Model("parent_t",       id = Models.IDField(), n = Models.IntegerField())
_g_other_parent() = Models.Model("other_parent_t", id = Models.IDField(), n = Models.IntegerField())

# The live (introspected) shape of a constrained key: the target's BINDING in `.to` plus the
# `to_table` breadcrumb, which is what the readers record.
function _g_live_fk(; to_table = "parent_t", pk_field = "id", on_delete = nothing,
                      null = true, unique = false, db_constraint = true)
  live = Models.ForeignKey("Parent_t"; pk_field = pk_field, null = null, unique = unique,
                           on_delete = on_delete, db_constraint = db_constraint)
  live.to_table = to_table
  return live
end

# The declared side carries a RESOLVED `PormGModel` in `.to`, which is what `set_models` leaves
# behind and what `fk_target_table` needs to render a `REFERENCES` clause.
_g_declared_fk(parent = _g_parent(); kwargs...) =
  Models.ForeignKey(parent; pk_field = "id", null = true, kwargs...)

# -- The corpus ----------------------------------------------------------------
# Each entry: name => (declared column, live column, declared column NAME, live column NAME).
# Equal names are an alteration; differing names are a RENAME (planned interactively).
const GOLDEN_CASES = Pair{String, NTuple{4, Any}}[
  # nothing changed - the control that must plan absolutely nothing
  "unchanged"            => (Models.CharField(max_length = 40), Models.CharField(max_length = 40), "col", "col"),
  # the type axis
  "char_to_int"          => (Models.IntegerField(), Models.CharField(max_length = 40), "col", "col"),
  "varchar_length"       => (Models.CharField(max_length = 80), Models.CharField(max_length = 40), "col", "col"),
  "decimal_precision"    => (Models.DecimalField(max_digits = 12, decimal_places = 4),
                             Models.DecimalField(max_digits = 10, decimal_places = 2), "col", "col"),
  "int_to_text"          => (Models.TextField(), Models.IntegerField(), "col", "col"),
  "int_to_duration"      => (Models.DurationField(), Models.IntegerField(), "col", "col"),
  # nullability, uniqueness, default, primary key
  "null_set"             => (Models.IntegerField(null = false), Models.IntegerField(null = true), "col", "col"),
  "null_drop"            => (Models.IntegerField(null = true), Models.IntegerField(null = false), "col", "col"),
  "unique_add"           => (Models.CharField(max_length = 40, unique = true), Models.CharField(max_length = 40), "col", "col"),
  "unique_drop"          => (Models.CharField(max_length = 40), Models.CharField(max_length = 40, unique = true), "col", "col"),
  "default_set"          => (Models.IntegerField(default = 7), Models.IntegerField(), "col", "col"),
  "default_drop"         => (Models.IntegerField(), Models.IntegerField(default = 7), "col", "col"),
  "default_change"       => (Models.IntegerField(default = 9), Models.IntegerField(default = 7), "col", "col"),
  "pk_add"               => (Models.CharField(max_length = 40, primary_key = true), Models.CharField(max_length = 40), "col", "col"),
  "pk_drop"              => (Models.CharField(max_length = 40), Models.CharField(max_length = 40, primary_key = true), "col", "col"),
  # identity (PostgreSQL) - the pair phase 1 review found crashing, plus the cross-struct pair
  "identity_drop"        => (Models.UUIDField(), Models.IDField(), "col", "col"),
  "identity_cross"       => (Models.IDField(), Models.IntegerField(), "col", "col"),
  # identity FLAVOUR, both directions (#523). Both sides are `IDField`, so type / primary_key /
  # unique all match and the delta is `[:identity]` alone - which is what makes these two the only
  # pairs in the corpus that reach `SET GENERATED` rather than ADD or DROP.
  "identity_set_always"  => (Models.IDField(generated_always = true), Models.IDField(), "col", "col"),
  "identity_set_by_default" => (Models.IDField(), Models.IDField(generated_always = true), "col", "col"),
  # CHECK-expressed facts
  "positive_check_add"   => (Models.PositiveIntegerField(), Models.IntegerField(), "col", "col"),
  "positive_check_drop"  => (Models.IntegerField(), Models.PositiveIntegerField(), "col", "col"),
  "positive_widen"       => (Models.PositiveIntegerField(), Models.PositiveSmallIntegerField(), "col", "col"),
  "binary_bound_change"  => (Models.BinaryField(max_length = 8), Models.BinaryField(max_length = 4), "col", "col"),
  "binary_from_text"     => (Models.BinaryField(max_length = 4), Models.TextField(), "col", "col"),
  # the reference axis
  "fk_add"               => (_g_declared_fk(), Models.BigIntegerField(null = true), "col", "col"),
  "fk_drop"              => (Models.BigIntegerField(null = true), _g_live_fk(), "col", "col"),
  "fk_repoint"           => (_g_declared_fk(_g_other_parent()), _g_live_fk(), "col", "col"),
  "fk_on_delete"         => (_g_declared_fk(; on_delete = Models.SET_NULL), _g_live_fk(on_delete = "CASCADE"), "col", "col"),
  "fk_constraint_off"    => (_g_declared_fk(; db_constraint = false), _g_live_fk(), "col", "col"),
  "fk_unchanged"         => (_g_declared_fk(), _g_live_fk(), "col", "col"),
  # a checks-only transition and its inverse, WITHOUT a rename - the controls for the three
  # rename+drop cases below
  "positive_to_text"     => (Models.TextField(), Models.PositiveIntegerField(), "col", "col"),
  # renames - an empty delta, a delta on the column, and a delta on the reference
  "rename_plain"         => (Models.CharField(max_length = 40), Models.CharField(max_length = 40), "col2", "col"),
  # renames that ALSO drop a constraint whose name only the catalog knows. Added after review: the
  # four `get_constraints_*` lookups have to ask for the PRE-rename column, and nothing here could
  # see that while the mocks answered for every column.
  "rename_and_drop_unique" => (Models.CharField(max_length = 40),
                               Models.CharField(max_length = 40, unique = true), "col2", "col"),
  "rename_and_drop_pk"     => (Models.CharField(max_length = 40),
                               Models.CharField(max_length = 40, primary_key = true), "col2", "col"),
  "rename_and_drop_check"  => (Models.TextField(), Models.PositiveIntegerField(), "col2", "col"),
  "rename_and_retype"    => (Models.IntegerField(), Models.CharField(max_length = 40), "col2", "col"),
  "rename_and_repoint"   => (_g_declared_fk(_g_other_parent()), _g_live_fk(), "col2", "col"),
  "rename_fk_unchanged"  => (_g_declared_fk(), _g_live_fk(), "col2", "col"),
]

# `_hash_field_name` ends in `randstring(8)`, so constraint and index names differ on every run.
# Normalizing those two suffixes is what makes a plan comparable at all; everything else is
# compared verbatim.
golden_normalize(sql::String) =
  replace(sql, r"_[a-z0-9]{8}_fk" => "_HASH_fk", r"_[a-z0-9]{8}_idx" => "_HASH_idx")

# `get_migration_plan` takes the LIVE models positionally and the DECLARED ones in `current_schema` —
# the planner's own (deliberately confusing) argument order.
function golden_plan(conn, declared_field, live_field, declared_name::String, live_name::String)
  settings = PormG.Configuration.Settings()
  settings.change_db = true
  declared = Models.Model("child_t"; id = Models.IDField(),
                          Symbol(declared_name) => declared_field,
                          note = Models.CharField(max_length = 40))
  live = Models.Model("child_t"; id = Models.IDField(),
                      Symbol(live_name) => live_field,
                      note = Models.CharField(max_length = 40))
  current_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
    :child_t => Dict{Symbol, Union{Bool, PormGModel}}(:model => declared, :exist => false))
  plan = if declared_name != live_name
    # A rename is only ever PROPOSED interactively; there is one candidate, so the answer is "1".
    answer, io = mktemp()
    write(io, "1\n")
    close(io)
    # stdout is swallowed as well as stdin fed: the planner PRINTS its rename question, and one copy
    # per rename case in the suite output buries everything else. Only the prompt goes there — a
    # failing assertion reports on stderr.
    open(answer) do stdin_file
      redirect_stdin(stdin_file) do
        redirect_stdout(devnull) do
          Migrations.get_migration_plan(PormGModel[live], current_schema, conn, settings; interactive = true)
        end
      end
    end
  else
    Migrations.get_migration_plan(PormGModel[live], current_schema, conn, settings; interactive = false)
  end
  return haskey(plan, :child_t) ?
         Pair{String,String}[String(k) => golden_normalize(String(v)) for (k, v) in plan[:child_t]] :
         Pair{String,String}[]
end

# ─────────────────────────────────────────────────────────────────────────────
# THE GOLDEN, captured on the base commit (ae5cf316) BEFORE phase 2 was written.
#
# Deliberate differences — the six entries where phase 2 intends to move plan text. Everything else
# in this dictionary is byte-for-byte what the pre-phase-2 planner emitted.
#
#   positive_check_add/PG, positive_check_drop/PG
#     BEFORE  ALTER COLUMN "col" TYPE integer;   (plus the ADD CHECK / DROP CONSTRAINT)
#     AFTER   the CHECK statement alone
#     WHY     On PostgreSQL `IntegerField` and `PositiveIntegerField` both render `integer`, so the
#             pair is a `:checks`-only delta and the column's type did not change. Phase 1's
#             `alter_attrs` mapped `:checks` onto `:type`, which emitted a no-op retype — an
#             ACCESS EXCLUSIVE lock and a table rewrite for nothing.
#
#   rename_and_retype/PG, rename_and_retype/SL
#     BEFORE  the RENAME alone
#     AFTER   the RENAME plus the column change (an ALTER on PostgreSQL, a rebuild on SQLite)
#     WHY     Decision 5. The rename branch's private copy of the alteration path only rebuilt when
#             the FOREIGN KEY definition had changed, so a rename that also retyped the column
#             dropped the retype on the floor and converged only on the NEXT makemigrations.
#
#   rename_and_repoint/PG, rename_fk_unchanged/PG, rename_fk_unchanged/SL
#     BEFORE  a trailing `Create index on col2`
#     AFTER   no index statement
#     WHY     The old branch dropped the pre-rename index and re-created it under a fresh hashed
#             name. RENAME COLUMN carries a column's indexes with it on both engines, so there was
#             nothing to re-create; `db_index` is outside the IR (`index_actions` owns it) and an
#             unchanged `db_index` is now correctly no action at all. STATED LIMIT: a rename that
#             also FLIPS `db_index` plans its index action one run later, when the column appears on
#             both sides of the diff.
#
# Post-review coverage — 4 pairs with no "before", because they exist to pin a fix made DURING
# review rather than a behaviour that was preserved:
#
#   rename_and_drop_unique, rename_and_drop_pk, rename_and_drop_check
#     A rename whose column change also needs a constraint DROP. Several statements in
#     `Dialect.alter_field` can only learn a constraint's name by ASKING the catalog, and at plan
#     time the catalog still knows the column by its PRE-rename name. `alter_field` was asking for
#     the post-rename one, so:
#       * `rename_and_drop_unique` / `_pk` planned the RENAME **alone** — the DROP was silently
#         omitted (self-healing on the next run, but exactly the ACTION class phase 2 closes);
#       * `rename_and_drop_check` planned `ALTER COLUMN … TYPE text` with the stale `>= 0` CHECK
#         still in place, which **PostgreSQL rejects** — a migration that cannot run.
#     Fixed by carrying the live column in the delta (`column_delta`'s `old_name`, read back as
#     `delta.old_spec.name`), and these pin it: the DROP names `child_t_col_check` — the PRE-rename
#     column — while the retype names `col2`.
#
#   positive_to_text
#     The non-rename control for the three above. Same column change, same DROP-then-TYPE order, so
#     the rename cases are asserting "a rename changes nothing about the alteration" rather than
#     just "some DDL appeared".
#
# #523 coverage — 2 pairs, also with no "before", because the plan they used to produce could not
# run at all:
#
#   identity_set_always, identity_set_by_default
#     A live identity column whose FLAVOUR moved — `GENERATED BY DEFAULT` ⇄ `GENERATED ALWAYS`, which
#     is what an operator produces by tightening a key so application code can no longer supply the
#     value. `ADD GENERATED … AS IDENTITY` is valid only on a column that is not an identity yet, so
#     PostgreSQL answered *"column "col" is already an identity column"* and the migration failed at
#     the server. There was no third arm: with both sides carrying an identity the pair landed in the
#     ADD branch. Now `SET GENERATED { ALWAYS | BY DEFAULT }`, one statement, no DROP and no ADD.
#     Both sides are `IDField`, so the delta is `[:identity]` alone — these are the only pairs in the
#     corpus that isolate the identity slot, and the `/SL` goldens are EMPTY because SQLite has no
#     flavour to change. `identity_drop` (DROP arm) and `identity_cross` (ADD arm) are unchanged.
# ─────────────────────────────────────────────────────────────────────────────
const PLAN_GOLDEN = Dict{String, Vector{Pair{String, String}}}(
  "unchanged/PG" => [
  ],
  "unchanged/SL" => [
  ],
  "char_to_int/PG" => [
    "Alter field: col" =>
      "ALTER TABLE \"child_t\" ALTER COLUMN \"col\" TYPE integer;",
  ],
  "char_to_int/SL" => [
    "Alter table: child_t" =>
      "DROP TABLE IF EXISTS \"child_t_new\";\nCREATE TABLE \"child_t_new\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,\n  \"col\" INTEGER NOT NULL,\n  \"note\" TEXT(40) NOT NULL\n);;\nINSERT INTO \"child_t_new\" (\"id\", \"col\", \"note\") SELECT \"id\", \"col\", \"note\" FROM \"child_t\";;\nDROP TABLE \"child_t\";\nALTER TABLE \"child_t_new\" RENAME TO \"child_t\";\nPRAGMA foreign_key_check(\"child_t\");",
  ],
  "varchar_length/PG" => [
    "Alter field: col" =>
      "ALTER TABLE \"child_t\" ALTER COLUMN \"col\" TYPE VARCHAR(80);",
  ],
  "varchar_length/SL" => [
    "Alter table: child_t" =>
      "DROP TABLE IF EXISTS \"child_t_new\";\nCREATE TABLE \"child_t_new\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,\n  \"col\" TEXT(80) NOT NULL,\n  \"note\" TEXT(40) NOT NULL\n);;\nINSERT INTO \"child_t_new\" (\"id\", \"col\", \"note\") SELECT \"id\", \"col\", \"note\" FROM \"child_t\";;\nDROP TABLE \"child_t\";\nALTER TABLE \"child_t_new\" RENAME TO \"child_t\";\nPRAGMA foreign_key_check(\"child_t\");",
  ],
  "decimal_precision/PG" => [
    "Alter field: col" =>
      "ALTER TABLE \"child_t\" ALTER COLUMN \"col\" TYPE DECIMAL(12, 4);",
  ],
  "decimal_precision/SL" => [
    "Alter table: child_t" =>
      "DROP TABLE IF EXISTS \"child_t_new\";\nCREATE TABLE \"child_t_new\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,\n  \"col\" DECIMAL(12, 4) NOT NULL,\n  \"note\" TEXT(40) NOT NULL\n);;\nINSERT INTO \"child_t_new\" (\"id\", \"col\", \"note\") SELECT \"id\", \"col\", \"note\" FROM \"child_t\";;\nDROP TABLE \"child_t\";\nALTER TABLE \"child_t_new\" RENAME TO \"child_t\";\nPRAGMA foreign_key_check(\"child_t\");",
  ],
  "int_to_text/PG" => [
    "Alter field: col" =>
      "ALTER TABLE \"child_t\" ALTER COLUMN \"col\" TYPE text;",
  ],
  "int_to_text/SL" => [
    "Alter table: child_t" =>
      "DROP TABLE IF EXISTS \"child_t_new\";\nCREATE TABLE \"child_t_new\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,\n  \"col\" TEXT NOT NULL,\n  \"note\" TEXT(40) NOT NULL\n);;\nINSERT INTO \"child_t_new\" (\"id\", \"col\", \"note\") SELECT \"id\", \"col\", \"note\" FROM \"child_t\";;\nDROP TABLE \"child_t\";\nALTER TABLE \"child_t_new\" RENAME TO \"child_t\";\nPRAGMA foreign_key_check(\"child_t\");",
  ],
  "int_to_duration/PG" => [
    "Alter field: col" =>
      "ALTER TABLE \"child_t\" ALTER COLUMN \"col\" TYPE INTERVAL USING make_interval(secs => \"col\"::double precision);",
  ],
  "int_to_duration/SL" => [
    "Alter table: child_t" =>
      "DROP TABLE IF EXISTS \"child_t_new\";\nCREATE TABLE \"child_t_new\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,\n  \"col\" INTERVAL NOT NULL,\n  \"note\" TEXT(40) NOT NULL\n);;\nINSERT INTO \"child_t_new\" (\"id\", \"col\", \"note\") SELECT \"id\", \"col\", \"note\" FROM \"child_t\";;\nDROP TABLE \"child_t\";\nALTER TABLE \"child_t_new\" RENAME TO \"child_t\";\nPRAGMA foreign_key_check(\"child_t\");",
  ],
  "null_set/PG" => [
    "Alter field: col" =>
      "ALTER TABLE \"child_t\" ALTER COLUMN \"col\" SET NOT NULL;",
  ],
  "null_set/SL" => [
    "Alter table: child_t" =>
      "DROP TABLE IF EXISTS \"child_t_new\";\nCREATE TABLE \"child_t_new\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,\n  \"col\" INTEGER NOT NULL,\n  \"note\" TEXT(40) NOT NULL\n);;\nINSERT INTO \"child_t_new\" (\"id\", \"col\", \"note\") SELECT \"id\", \"col\", \"note\" FROM \"child_t\";;\nDROP TABLE \"child_t\";\nALTER TABLE \"child_t_new\" RENAME TO \"child_t\";\nPRAGMA foreign_key_check(\"child_t\");",
  ],
  "null_drop/PG" => [
    "Alter field: col" =>
      "ALTER TABLE \"child_t\" ALTER COLUMN \"col\" DROP NOT NULL;",
  ],
  "null_drop/SL" => [
    "Alter table: child_t" =>
      "DROP TABLE IF EXISTS \"child_t_new\";\nCREATE TABLE \"child_t_new\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,\n  \"col\" INTEGER NULL,\n  \"note\" TEXT(40) NOT NULL\n);;\nINSERT INTO \"child_t_new\" (\"id\", \"col\", \"note\") SELECT \"id\", \"col\", \"note\" FROM \"child_t\";;\nDROP TABLE \"child_t\";\nALTER TABLE \"child_t_new\" RENAME TO \"child_t\";\nPRAGMA foreign_key_check(\"child_t\");",
  ],
  "unique_add/PG" => [
    "Alter field: col" =>
      "ALTER TABLE \"child_t\" ADD UNIQUE (\"col\");",
  ],
  "unique_add/SL" => [
    "Alter table: child_t" =>
      "DROP TABLE IF EXISTS \"child_t_new\";\nCREATE TABLE \"child_t_new\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,\n  \"col\" TEXT(40) UNIQUE NOT NULL,\n  \"note\" TEXT(40) NOT NULL\n);;\nINSERT INTO \"child_t_new\" (\"id\", \"col\", \"note\") SELECT \"id\", \"col\", \"note\" FROM \"child_t\";;\nDROP TABLE \"child_t\";\nALTER TABLE \"child_t_new\" RENAME TO \"child_t\";\nPRAGMA foreign_key_check(\"child_t\");",
  ],
  "unique_drop/PG" => [
    "Alter field: col" =>
      "ALTER TABLE \"child_t\" DROP CONSTRAINT \"child_t_col_key\";",
  ],
  "unique_drop/SL" => [
    "Alter table: child_t" =>
      "DROP TABLE IF EXISTS \"child_t_new\";\nCREATE TABLE \"child_t_new\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,\n  \"col\" TEXT(40) NOT NULL,\n  \"note\" TEXT(40) NOT NULL\n);;\nINSERT INTO \"child_t_new\" (\"id\", \"col\", \"note\") SELECT \"id\", \"col\", \"note\" FROM \"child_t\";;\nDROP TABLE \"child_t\";\nALTER TABLE \"child_t_new\" RENAME TO \"child_t\";\nPRAGMA foreign_key_check(\"child_t\");",
  ],
  "default_set/PG" => [
    "Alter field: col" =>
      "ALTER TABLE \"child_t\" ALTER COLUMN \"col\" SET DEFAULT 7;",
  ],
  "default_set/SL" => [
    "Alter table: child_t" =>
      "DROP TABLE IF EXISTS \"child_t_new\";\nCREATE TABLE \"child_t_new\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,\n  \"col\" INTEGER NOT NULL DEFAULT 7,\n  \"note\" TEXT(40) NOT NULL\n);;\nINSERT INTO \"child_t_new\" (\"id\", \"col\", \"note\") SELECT \"id\", \"col\", \"note\" FROM \"child_t\";;\nDROP TABLE \"child_t\";\nALTER TABLE \"child_t_new\" RENAME TO \"child_t\";\nPRAGMA foreign_key_check(\"child_t\");",
  ],
  "default_drop/PG" => [
    "Alter field: col" =>
      "ALTER TABLE \"child_t\" ALTER COLUMN \"col\" DROP DEFAULT;",
  ],
  "default_drop/SL" => [
    "Alter table: child_t" =>
      "DROP TABLE IF EXISTS \"child_t_new\";\nCREATE TABLE \"child_t_new\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,\n  \"col\" INTEGER NOT NULL,\n  \"note\" TEXT(40) NOT NULL\n);;\nINSERT INTO \"child_t_new\" (\"id\", \"col\", \"note\") SELECT \"id\", \"col\", \"note\" FROM \"child_t\";;\nDROP TABLE \"child_t\";\nALTER TABLE \"child_t_new\" RENAME TO \"child_t\";\nPRAGMA foreign_key_check(\"child_t\");",
  ],
  "default_change/PG" => [
    "Alter field: col" =>
      "ALTER TABLE \"child_t\" ALTER COLUMN \"col\" SET DEFAULT 9;",
  ],
  "default_change/SL" => [
    "Alter table: child_t" =>
      "DROP TABLE IF EXISTS \"child_t_new\";\nCREATE TABLE \"child_t_new\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,\n  \"col\" INTEGER NOT NULL DEFAULT 9,\n  \"note\" TEXT(40) NOT NULL\n);;\nINSERT INTO \"child_t_new\" (\"id\", \"col\", \"note\") SELECT \"id\", \"col\", \"note\" FROM \"child_t\";;\nDROP TABLE \"child_t\";\nALTER TABLE \"child_t_new\" RENAME TO \"child_t\";\nPRAGMA foreign_key_check(\"child_t\");",
  ],
  "pk_add/PG" => [
    "Alter field: col" =>
      "ALTER TABLE \"child_t\" ADD PRIMARY KEY (\"col\");",
  ],
  "pk_add/SL" => [
    "Alter table: child_t" =>
      "DROP TABLE IF EXISTS \"child_t_new\";\nCREATE TABLE \"child_t_new\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,\n  \"col\" TEXT(40) PRIMARY KEY NOT NULL,\n  \"note\" TEXT(40) NOT NULL\n);;\nINSERT INTO \"child_t_new\" (\"id\", \"col\", \"note\") SELECT \"id\", \"col\", \"note\" FROM \"child_t\";;\nDROP TABLE \"child_t\";\nALTER TABLE \"child_t_new\" RENAME TO \"child_t\";\nPRAGMA foreign_key_check(\"child_t\");",
  ],
  "pk_drop/PG" => [
    "Alter field: col" =>
      "ALTER TABLE \"child_t\" DROP CONSTRAINT \"child_t_pkey\";",
  ],
  "pk_drop/SL" => [
    "Alter table: child_t" =>
      "DROP TABLE IF EXISTS \"child_t_new\";\nCREATE TABLE \"child_t_new\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,\n  \"col\" TEXT(40) NOT NULL,\n  \"note\" TEXT(40) NOT NULL\n);;\nINSERT INTO \"child_t_new\" (\"id\", \"col\", \"note\") SELECT \"id\", \"col\", \"note\" FROM \"child_t\";;\nDROP TABLE \"child_t\";\nALTER TABLE \"child_t_new\" RENAME TO \"child_t\";\nPRAGMA foreign_key_check(\"child_t\");",
  ],
  "identity_drop/PG" => [
    "Alter field: col" =>
      "ALTER TABLE \"child_t\" ALTER COLUMN \"col\" DROP IDENTITY;\nALTER TABLE \"child_t\" ALTER COLUMN \"col\" TYPE uuid;\nALTER TABLE \"child_t\" DROP CONSTRAINT \"child_t_col_key\";\nALTER TABLE \"child_t\" DROP CONSTRAINT \"child_t_pkey\";",
  ],
  "identity_drop/SL" => [
    "Alter table: child_t" =>
      "DROP TABLE IF EXISTS \"child_t_new\";\nCREATE TABLE \"child_t_new\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,\n  \"col\" TEXT NOT NULL,\n  \"note\" TEXT(40) NOT NULL\n);;\nINSERT INTO \"child_t_new\" (\"id\", \"col\", \"note\") SELECT \"id\", \"col\", \"note\" FROM \"child_t\";;\nDROP TABLE \"child_t\";\nALTER TABLE \"child_t_new\" RENAME TO \"child_t\";\nPRAGMA foreign_key_check(\"child_t\");",
  ],
  "identity_cross/PG" => [
    "Alter field: col" =>
      "ALTER TABLE \"child_t\" ALTER COLUMN \"col\" TYPE bigint;\nALTER TABLE \"child_t\" ADD UNIQUE (\"col\");\nALTER TABLE \"child_t\" ADD PRIMARY KEY (\"col\");\nALTER TABLE \"child_t\" ALTER COLUMN \"col\" ADD GENERATED BY DEFAULT AS IDENTITY;",
  ],
  "identity_cross/SL" => [
    "Alter table: child_t" =>
      "DROP TABLE IF EXISTS \"child_t_new\";\nCREATE TABLE \"child_t_new\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,\n  \"col\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,\n  \"note\" TEXT(40) NOT NULL\n);;\nINSERT INTO \"child_t_new\" (\"id\", \"col\", \"note\") SELECT \"id\", \"col\", \"note\" FROM \"child_t\";;\nDROP TABLE \"child_t\";\nALTER TABLE \"child_t_new\" RENAME TO \"child_t\";\nPRAGMA foreign_key_check(\"child_t\");",
  ],
  "identity_set_always/PG" => [
    "Alter field: col" =>
      "ALTER TABLE \"child_t\" ALTER COLUMN \"col\" SET GENERATED ALWAYS;",
  ],
  "identity_set_always/SL" => [
  ],
  "identity_set_by_default/PG" => [
    "Alter field: col" =>
      "ALTER TABLE \"child_t\" ALTER COLUMN \"col\" SET GENERATED BY DEFAULT;",
  ],
  "identity_set_by_default/SL" => [
  ],
  "positive_check_add/PG" => [
    "Alter field: col" =>
      "ALTER TABLE \"child_t\" ADD CHECK (\"col\" >= 0);",
  ],
  "positive_check_add/SL" => [
    "Alter table: child_t" =>
      "DROP TABLE IF EXISTS \"child_t_new\";\nCREATE TABLE \"child_t_new\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,\n  \"col\" INTEGER UNSIGNED NOT NULL CHECK (\"col\" >= 0),\n  \"note\" TEXT(40) NOT NULL\n);;\nINSERT INTO \"child_t_new\" (\"id\", \"col\", \"note\") SELECT \"id\", \"col\", \"note\" FROM \"child_t\";;\nDROP TABLE \"child_t\";\nALTER TABLE \"child_t_new\" RENAME TO \"child_t\";\nPRAGMA foreign_key_check(\"child_t\");",
  ],
  "positive_check_drop/PG" => [
    "Alter field: col" =>
      "ALTER TABLE \"child_t\" DROP CONSTRAINT \"child_t_col_check\";",
  ],
  "positive_check_drop/SL" => [
    "Alter table: child_t" =>
      "DROP TABLE IF EXISTS \"child_t_new\";\nCREATE TABLE \"child_t_new\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,\n  \"col\" INTEGER NOT NULL,\n  \"note\" TEXT(40) NOT NULL\n);;\nINSERT INTO \"child_t_new\" (\"id\", \"col\", \"note\") SELECT \"id\", \"col\", \"note\" FROM \"child_t\";;\nDROP TABLE \"child_t\";\nALTER TABLE \"child_t_new\" RENAME TO \"child_t\";\nPRAGMA foreign_key_check(\"child_t\");",
  ],
  "positive_widen/PG" => [
    "Alter field: col" =>
      "ALTER TABLE \"child_t\" ALTER COLUMN \"col\" TYPE integer;",
  ],
  "positive_widen/SL" => [
    "Alter table: child_t" =>
      "DROP TABLE IF EXISTS \"child_t_new\";\nCREATE TABLE \"child_t_new\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,\n  \"col\" INTEGER UNSIGNED NOT NULL CHECK (\"col\" >= 0),\n  \"note\" TEXT(40) NOT NULL\n);;\nINSERT INTO \"child_t_new\" (\"id\", \"col\", \"note\") SELECT \"id\", \"col\", \"note\" FROM \"child_t\";;\nDROP TABLE \"child_t\";\nALTER TABLE \"child_t_new\" RENAME TO \"child_t\";\nPRAGMA foreign_key_check(\"child_t\");",
  ],
  "binary_bound_change/PG" => [
    "Alter field: col" =>
      "ALTER TABLE \"child_t\" DROP CONSTRAINT \"child_t_col_bytes\";\nALTER TABLE \"child_t\" ADD CHECK (octet_length(\"col\") <= 8);",
  ],
  "binary_bound_change/SL" => [
    "Alter table: child_t" =>
      "DROP TABLE IF EXISTS \"child_t_new\";\nCREATE TABLE \"child_t_new\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,\n  \"col\" BLOB NOT NULL CHECK (length(\"col\") <= 8),\n  \"note\" TEXT(40) NOT NULL\n);;\nINSERT INTO \"child_t_new\" (\"id\", \"col\", \"note\") SELECT \"id\", CAST(\"col\" AS BLOB), \"note\" FROM \"child_t\";;\nDROP TABLE \"child_t\";\nALTER TABLE \"child_t_new\" RENAME TO \"child_t\";\nPRAGMA foreign_key_check(\"child_t\");",
  ],
  "binary_from_text/PG" => [
    "Alter field: col" =>
      "ALTER TABLE \"child_t\" ALTER COLUMN \"col\" TYPE bytea USING convert_to(\"col\", 'UTF8');\nALTER TABLE \"child_t\" ADD CHECK (octet_length(\"col\") <= 4);",
  ],
  "binary_from_text/SL" => [
    "Alter table: child_t" =>
      "DROP TABLE IF EXISTS \"child_t_new\";\nCREATE TABLE \"child_t_new\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,\n  \"col\" BLOB NOT NULL CHECK (length(\"col\") <= 4),\n  \"note\" TEXT(40) NOT NULL\n);;\nINSERT INTO \"child_t_new\" (\"id\", \"col\", \"note\") SELECT \"id\", CAST(\"col\" AS BLOB), \"note\" FROM \"child_t\";;\nDROP TABLE \"child_t\";\nALTER TABLE \"child_t_new\" RENAME TO \"child_t\";\nPRAGMA foreign_key_check(\"child_t\");",
  ],
  "fk_add/PG" => [
    "New foreign key: col" =>
      "ALTER TABLE \"child_t\" ADD CONSTRAINT \"child_t_col_HASH_fk\" FOREIGN KEY (\"col\") REFERENCES \"parent_t\" (\"id\") ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED;",
    "Create index on col" =>
      "CREATE INDEX IF NOT EXISTS \"child_t_col_HASH_idx\" ON \"child_t\" (\"col\");",
  ],
  "fk_add/SL" => [
    "Alter table: child_t" =>
      "DROP TABLE IF EXISTS \"child_t_new\";\nCREATE TABLE \"child_t_new\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,\n  \"col\" INTEGER NULL,\n  \"note\" TEXT(40) NOT NULL,\n  FOREIGN KEY (\"col\") REFERENCES \"parent_t\"(\"id\") ON DELETE NO ACTION\n);;\nINSERT INTO \"child_t_new\" (\"id\", \"col\", \"note\") SELECT \"id\", \"col\", \"note\" FROM \"child_t\";;\nDROP TABLE \"child_t\";\nALTER TABLE \"child_t_new\" RENAME TO \"child_t\";\nPRAGMA foreign_key_check(\"child_t\");",
    "Create index on col" =>
      "CREATE INDEX IF NOT EXISTS \"child_t_col_HASH_idx\" ON \"child_t\" (\"col\");",
  ],
  "fk_drop/PG" => [
    "Remove foreign key: col" =>
      "ALTER TABLE \"child_t\" DROP CONSTRAINT \"child_t_col_HASH_fk\";",
  ],
  "fk_drop/SL" => [
    "Alter table: child_t" =>
      "DROP TABLE IF EXISTS \"child_t_new\";\nCREATE TABLE \"child_t_new\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,\n  \"col\" INTEGER NULL,\n  \"note\" TEXT(40) NOT NULL\n);;\nINSERT INTO \"child_t_new\" (\"id\", \"col\", \"note\") SELECT \"id\", \"col\", \"note\" FROM \"child_t\";;\nDROP TABLE \"child_t\";\nALTER TABLE \"child_t_new\" RENAME TO \"child_t\";\nPRAGMA foreign_key_check(\"child_t\");",
  ],
  "fk_repoint/PG" => [
    "Remove foreign key: col" =>
      "ALTER TABLE \"child_t\" DROP CONSTRAINT \"child_t_col_HASH_fk\";",
    "New foreign key: col" =>
      "ALTER TABLE \"child_t\" ADD CONSTRAINT \"child_t_col_HASH_fk\" FOREIGN KEY (\"col\") REFERENCES \"other_parent_t\" (\"id\") ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED;",
  ],
  "fk_repoint/SL" => [
    "Alter table: child_t" =>
      "DROP TABLE IF EXISTS \"child_t_new\";\nCREATE TABLE \"child_t_new\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,\n  \"col\" INTEGER NULL,\n  \"note\" TEXT(40) NOT NULL,\n  FOREIGN KEY (\"col\") REFERENCES \"other_parent_t\"(\"id\") ON DELETE NO ACTION\n);;\nINSERT INTO \"child_t_new\" (\"id\", \"col\", \"note\") SELECT \"id\", \"col\", \"note\" FROM \"child_t\";;\nDROP TABLE \"child_t\";\nALTER TABLE \"child_t_new\" RENAME TO \"child_t\";\nPRAGMA foreign_key_check(\"child_t\");",
  ],
  "fk_on_delete/PG" => [
    "Remove foreign key: col" =>
      "ALTER TABLE \"child_t\" DROP CONSTRAINT \"child_t_col_HASH_fk\";",
    "New foreign key: col" =>
      "ALTER TABLE \"child_t\" ADD CONSTRAINT \"child_t_col_HASH_fk\" FOREIGN KEY (\"col\") REFERENCES \"parent_t\" (\"id\") ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED;",
  ],
  "fk_on_delete/SL" => [
    "Alter table: child_t" =>
      "DROP TABLE IF EXISTS \"child_t_new\";\nCREATE TABLE \"child_t_new\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,\n  \"col\" INTEGER NULL,\n  \"note\" TEXT(40) NOT NULL,\n  FOREIGN KEY (\"col\") REFERENCES \"parent_t\"(\"id\") ON DELETE SET NULL\n);;\nINSERT INTO \"child_t_new\" (\"id\", \"col\", \"note\") SELECT \"id\", \"col\", \"note\" FROM \"child_t\";;\nDROP TABLE \"child_t\";\nALTER TABLE \"child_t_new\" RENAME TO \"child_t\";\nPRAGMA foreign_key_check(\"child_t\");",
  ],
  "fk_constraint_off/PG" => [
    "Remove foreign key: col" =>
      "ALTER TABLE \"child_t\" DROP CONSTRAINT \"child_t_col_HASH_fk\";",
  ],
  "fk_constraint_off/SL" => [
    "Alter table: child_t" =>
      "DROP TABLE IF EXISTS \"child_t_new\";\nCREATE TABLE \"child_t_new\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,\n  \"col\" INTEGER NULL,\n  \"note\" TEXT(40) NOT NULL\n);;\nINSERT INTO \"child_t_new\" (\"id\", \"col\", \"note\") SELECT \"id\", \"col\", \"note\" FROM \"child_t\";;\nDROP TABLE \"child_t\";\nALTER TABLE \"child_t_new\" RENAME TO \"child_t\";\nPRAGMA foreign_key_check(\"child_t\");",
  ],
  "fk_unchanged/PG" => [
  ],
  "fk_unchanged/SL" => [
  ],
  "positive_to_text/PG" => [
    "Alter field: col" =>
      "ALTER TABLE \"child_t\" DROP CONSTRAINT \"child_t_col_check\";\nALTER TABLE \"child_t\" ALTER COLUMN \"col\" TYPE text;",
  ],
  "positive_to_text/SL" => [
    "Alter table: child_t" =>
      "DROP TABLE IF EXISTS \"child_t_new\";\nCREATE TABLE \"child_t_new\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,\n  \"col\" TEXT NOT NULL,\n  \"note\" TEXT(40) NOT NULL\n);;\nINSERT INTO \"child_t_new\" (\"id\", \"col\", \"note\") SELECT \"id\", \"col\", \"note\" FROM \"child_t\";;\nDROP TABLE \"child_t\";\nALTER TABLE \"child_t_new\" RENAME TO \"child_t\";\nPRAGMA foreign_key_check(\"child_t\");",
  ],
  "rename_plain/PG" => [
    "Rename field: col2" =>
      "ALTER TABLE \"child_t\" RENAME COLUMN \"col\" TO \"col2\";",
  ],
  "rename_plain/SL" => [
    "Rename field: col2" =>
      "ALTER TABLE \"child_t\" RENAME COLUMN \"col\" TO \"col2\";",
  ],
  "rename_and_drop_unique/PG" => [
    "Rename field: col2" =>
      "ALTER TABLE \"child_t\" RENAME COLUMN \"col\" TO \"col2\";",
    "Alter field: col2" =>
      "ALTER TABLE \"child_t\" DROP CONSTRAINT \"child_t_col_key\";",
  ],
  "rename_and_drop_unique/SL" => [
    "Rename field: col2" =>
      "ALTER TABLE \"child_t\" RENAME COLUMN \"col\" TO \"col2\";",
    "Alter table: child_t" =>
      "DROP TABLE IF EXISTS \"child_t_new\";\nCREATE TABLE \"child_t_new\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,\n  \"col2\" TEXT(40) NOT NULL,\n  \"note\" TEXT(40) NOT NULL\n);;\nINSERT INTO \"child_t_new\" (\"id\", \"col2\", \"note\") SELECT \"id\", \"col2\", \"note\" FROM \"child_t\";;\nDROP TABLE \"child_t\";\nALTER TABLE \"child_t_new\" RENAME TO \"child_t\";\nPRAGMA foreign_key_check(\"child_t\");",
  ],
  "rename_and_drop_pk/PG" => [
    "Rename field: col2" =>
      "ALTER TABLE \"child_t\" RENAME COLUMN \"col\" TO \"col2\";",
    "Alter field: col2" =>
      "ALTER TABLE \"child_t\" DROP CONSTRAINT \"child_t_pkey\";",
  ],
  "rename_and_drop_pk/SL" => [
    "Rename field: col2" =>
      "ALTER TABLE \"child_t\" RENAME COLUMN \"col\" TO \"col2\";",
    "Alter table: child_t" =>
      "DROP TABLE IF EXISTS \"child_t_new\";\nCREATE TABLE \"child_t_new\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,\n  \"col2\" TEXT(40) NOT NULL,\n  \"note\" TEXT(40) NOT NULL\n);;\nINSERT INTO \"child_t_new\" (\"id\", \"col2\", \"note\") SELECT \"id\", \"col2\", \"note\" FROM \"child_t\";;\nDROP TABLE \"child_t\";\nALTER TABLE \"child_t_new\" RENAME TO \"child_t\";\nPRAGMA foreign_key_check(\"child_t\");",
  ],
  "rename_and_drop_check/PG" => [
    "Rename field: col2" =>
      "ALTER TABLE \"child_t\" RENAME COLUMN \"col\" TO \"col2\";",
    "Alter field: col2" =>
      "ALTER TABLE \"child_t\" DROP CONSTRAINT \"child_t_col_check\";\nALTER TABLE \"child_t\" ALTER COLUMN \"col2\" TYPE text;",
  ],
  "rename_and_drop_check/SL" => [
    "Rename field: col2" =>
      "ALTER TABLE \"child_t\" RENAME COLUMN \"col\" TO \"col2\";",
    "Alter table: child_t" =>
      "DROP TABLE IF EXISTS \"child_t_new\";\nCREATE TABLE \"child_t_new\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,\n  \"col2\" TEXT NOT NULL,\n  \"note\" TEXT(40) NOT NULL\n);;\nINSERT INTO \"child_t_new\" (\"id\", \"col2\", \"note\") SELECT \"id\", \"col2\", \"note\" FROM \"child_t\";;\nDROP TABLE \"child_t\";\nALTER TABLE \"child_t_new\" RENAME TO \"child_t\";\nPRAGMA foreign_key_check(\"child_t\");",
  ],
  "rename_and_retype/PG" => [
    "Rename field: col2" =>
      "ALTER TABLE \"child_t\" RENAME COLUMN \"col\" TO \"col2\";",
    "Alter field: col2" =>
      "ALTER TABLE \"child_t\" ALTER COLUMN \"col2\" TYPE integer;",
  ],
  "rename_and_retype/SL" => [
    "Rename field: col2" =>
      "ALTER TABLE \"child_t\" RENAME COLUMN \"col\" TO \"col2\";",
    "Alter table: child_t" =>
      "DROP TABLE IF EXISTS \"child_t_new\";\nCREATE TABLE \"child_t_new\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,\n  \"col2\" INTEGER NOT NULL,\n  \"note\" TEXT(40) NOT NULL\n);;\nINSERT INTO \"child_t_new\" (\"id\", \"col2\", \"note\") SELECT \"id\", \"col2\", \"note\" FROM \"child_t\";;\nDROP TABLE \"child_t\";\nALTER TABLE \"child_t_new\" RENAME TO \"child_t\";\nPRAGMA foreign_key_check(\"child_t\");",
  ],
  "rename_and_repoint/PG" => [
    "Remove foreign key: col" =>
      "ALTER TABLE \"child_t\" DROP CONSTRAINT \"child_t_col_HASH_fk\";",
    "Rename field: col2" =>
      "ALTER TABLE \"child_t\" RENAME COLUMN \"col\" TO \"col2\";",
    "New foreign key: col2" =>
      "ALTER TABLE \"child_t\" ADD CONSTRAINT \"child_t_col2_HASH_fk\" FOREIGN KEY (\"col2\") REFERENCES \"other_parent_t\" (\"id\") ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED;",
  ],
  "rename_and_repoint/SL" => [
    "Rename field: col2" =>
      "ALTER TABLE \"child_t\" RENAME COLUMN \"col\" TO \"col2\";",
    "Alter table: child_t" =>
      "DROP TABLE IF EXISTS \"child_t_new\";\nCREATE TABLE \"child_t_new\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,\n  \"col2\" INTEGER NULL,\n  \"note\" TEXT(40) NOT NULL,\n  FOREIGN KEY (\"col2\") REFERENCES \"other_parent_t\"(\"id\") ON DELETE NO ACTION\n);;\nINSERT INTO \"child_t_new\" (\"id\", \"col2\", \"note\") SELECT \"id\", \"col2\", \"note\" FROM \"child_t\";;\nDROP TABLE \"child_t\";\nALTER TABLE \"child_t_new\" RENAME TO \"child_t\";\nPRAGMA foreign_key_check(\"child_t\");",
  ],
  "rename_fk_unchanged/PG" => [
    "Rename field: col2" =>
      "ALTER TABLE \"child_t\" RENAME COLUMN \"col\" TO \"col2\";",
  ],
  "rename_fk_unchanged/SL" => [
    "Rename field: col2" =>
      "ALTER TABLE \"child_t\" RENAME COLUMN \"col\" TO \"col2\";",
  ],
)

@testset "Plan actions from the typed delta (#507 phase 2)" begin

  # ───────────────────────────────────────────────────────────────────────────
  # Golden plan: the rendered plan for 38 column pairs on both engines
  # Every statement `makemigrations` would write, pinned against what the planner emitted BEFORE
  # phase 2. This is the behavioural contract of the refactor: the plan text does not move except
  # where a fix intends it to, and the six intended moves are enumerated above with their reasons.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "the rendered plan is unchanged, statement for statement" begin
    for (name, (declared, live, dname, lname)) in GOLDEN_CASES
      for (engine, conn) in (("PG", GPG507), ("SL", GSL507))
        key = "$(name)/$(engine)"
        @assert haskey(PLAN_GOLDEN, key) "no golden captured for $(key)"
        # Warnings are silenced here (they are asserted by the dedicated testsets below); a plan
        # that RAISES must fail as a failure, not as a caught error, so nothing is caught.
        steps = with_logger(NullLogger()) do
          golden_plan(conn, declared, live, dname, lname)
        end
        # Compared as an ORDERED vector, not a Dict: the order of the steps inside a table's plan is
        # the order they execute in, and the DROP-before-ADD of a re-pointed foreign key is only
        # correct because of it (#498).
        @test steps == PLAN_GOLDEN[key]
      end
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # The intended differences, asserted as intent rather than as a snapshot
  # A golden dictionary records WHAT the plan is; these assert WHY. If someone regenerates the
  # golden from a future build, these still say what phase 2 promised.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "the seven intended plan-text changes" begin
    # A checks-only transition emits the CHECK and nothing else. `integer` -> `integer` is not a
    # type change, and the pre-phase-2 planner's redundant retype was a table rewrite for nothing.
    add_sql = join([v for (_, v) in PLAN_GOLDEN["positive_check_add/PG"]], "\n")
    @test occursin("ADD CHECK", add_sql)
    @test !occursin("TYPE integer", add_sql)

    drop_sql = join([v for (_, v) in PLAN_GOLDEN["positive_check_drop/PG"]], "\n")
    @test occursin("DROP CONSTRAINT", drop_sql)
    @test !occursin("TYPE integer", drop_sql)

    # ... while a REAL type change between two positive-integer fields keeps its retype and churns
    # no constraint. This is the negative control for the two assertions above: they must not have
    # passed by making the type branch unreachable.
    widen_sql = join([v for (_, v) in PLAN_GOLDEN["positive_widen/PG"]], "\n")
    @test occursin("TYPE integer", widen_sql)
    @test !occursin("ADD CHECK", widen_sql)
    @test !occursin("DROP CONSTRAINT", widen_sql)

    # Decision 5: a rename whose column ALSO changed now carries the change. Pre-phase-2 this plan
    # was the RENAME alone and the retype was silently deferred to the next makemigrations.
    retype_keys = [k for (k, _) in PLAN_GOLDEN["rename_and_retype/PG"]]
    @test retype_keys == ["Rename field: col2", "Alter field: col2"]
    @test occursin("TYPE integer", PLAN_GOLDEN["rename_and_retype/PG"][2][2])
    # On SQLite the same delta means the table rebuild, and the RENAME must come FIRST so the
    # rebuild's INSERT..SELECT (which copies by the NEW name) finds the column.
    @test [k for (k, _) in PLAN_GOLDEN["rename_and_retype/SL"]] ==
          ["Rename field: col2", "Alter table: child_t"]

    # #504, by construction: a rename whose reference did not move plans the RENAME and nothing
    # else — no second FOREIGN KEY, and no index churn either.
    @test [k for (k, _) in PLAN_GOLDEN["rename_fk_unchanged/PG"]] == ["Rename field: col2"]
    @test [k for (k, _) in PLAN_GOLDEN["rename_fk_unchanged/SL"]] == ["Rename field: col2"]

    # A rename that DOES re-point still drops before it renames and adds after — the ordering
    # `_plan_column_change!` exists to hold. The DROP is keyed by the PRE-rename column, because at
    # plan time the catalog has not been renamed yet; the ADD by the new one.
    @test [k for (k, _) in PLAN_GOLDEN["rename_and_repoint/PG"]] ==
          ["Remove foreign key: col", "Rename field: col2", "New foreign key: col2"]
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Identity: three arms, not two (#523)
  # `ADD GENERATED … AS IDENTITY` is valid only on a column that is not an identity yet; PostgreSQL
  # answers *"column "c" is already an identity column"* otherwise. Changing the flavour of an
  # existing identity is `SET GENERATED { ALWAYS | BY DEFAULT }`. Before #523 there was no third arm,
  # so a flavour flip fell into the ADD branch and every such migration failed at the SERVER — no
  # string-level check could see it, which is why the integration phase in
  # `test_migration_bootstrap.jl` executes it against a live catalog too.
  #
  # Asserted here as intent rather than only as golden text: the discriminator is
  # `delta.old_spec.identity !== nothing`, and these say what each of the three arms owes.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "identity: flavour change renders SET, not ADD or DROP (#523)" begin
    always = Models.IDField(generated_always = true)
    bydef  = Models.IDField()

    # Both directions of the flavour flip. The delta is `[:identity]` alone — both sides are
    # `IDField`, so type / primary_key / unique cannot differ — and the plan is ONE statement.
    for (declared, live, expected) in ((always, bydef, "SET GENERATED ALWAYS"),
                                       (bydef, always, "SET GENERATED BY DEFAULT"))
      delta = Migrations.column_delta(declared, live, GPG507; name = "col")
      # The diff was never the bug: it correctly reported the identity difference all along.
      @test delta.changed == [:identity]
      sql = Dialect.alter_field(GPG507, "child_t", "col", declared, delta)
      @test occursin(expected, sql)
      # The two statements PostgreSQL would refuse, or that would destroy and re-create the
      # sequence: neither may appear. `ADD` is the actual #523 bug; `DROP IDENTITY` would discard
      # the sequence's current value.
      @test !occursin("ADD GENERATED", sql)
      @test !occursin("DROP IDENTITY", sql)
      @test count(!isempty, split(strip(sql), '\n')) == 1
    end

    # The two arms that already worked must keep working — this is the negative control for the
    # branch above, which must not have been reached by making ADD/DROP unreachable.
    #
    # ADD: the live column is not an identity at all (`IntegerField`), so the column BECOMES one and
    # `ADD GENERATED` is right. It stays AFTER the type change, since a column can only become an
    # identity once it is already an integer type.
    add_delta = Migrations.column_delta(bydef, Models.IntegerField(), GPG507; name = "col")
    add_sql = Dialect.alter_field(GPG507, "child_t", "col", bydef, add_delta)
    @test occursin("ADD GENERATED BY DEFAULT AS IDENTITY", add_sql)
    @test !occursin("SET GENERATED", add_sql)
    @test findfirst("TYPE bigint", add_sql).start < findfirst("ADD GENERATED", add_sql).start

    # ADD, the ALWAYS flavour — the one arm the corpus never reached before #523, because no pair
    # declared `generated_always` over a non-identity column.
    add_always_delta = Migrations.column_delta(always, Models.IntegerField(), GPG507; name = "col")
    add_always_sql = Dialect.alter_field(GPG507, "child_t", "col", always,
                                         add_always_delta)
    @test occursin("ADD GENERATED ALWAYS AS IDENTITY", add_always_sql)
    @test !occursin("SET GENERATED", add_always_sql)

    # DROP: the declared column is not an identity, so the identity goes away — and the statement
    # stays BEFORE the type change, because PostgreSQL enforces the integer restriction DURING
    # `ALTER COLUMN … TYPE` and the later DROP would never run.
    drop_delta = Migrations.column_delta(Models.UUIDField(), bydef, GPG507; name = "col")
    drop_sql = Dialect.alter_field(GPG507, "child_t", "col", Models.UUIDField(), drop_delta)
    @test occursin("DROP IDENTITY", drop_sql)
    @test !occursin("SET GENERATED", drop_sql)
    @test !occursin("ADD GENERATED", drop_sql)
    @test findfirst("DROP IDENTITY", drop_sql).start < findfirst("TYPE uuid", drop_sql).start

    # SQLite has no identity flavour to change: `field_to_column` renders
    # `PRIMARY KEY AUTOINCREMENT` for any `sIDField` primary key whatever `generated_always` says,
    # so the two sides compile to the same spec and there is no delta to act on. An engine that
    # cannot express the difference must not plan DDL for it.
    @test isempty(Migrations.column_delta(always, bydef, GSL507; name = "col"))
  end

  # ───────────────────────────────────────────────────────────────────────────
  # A rename asks the catalog for the column it still knows — FOUND IN REVIEW
  #
  # `Dialect.alter_field` learns four constraint names by asking the catalog (the two CHECK drops,
  # the UNIQUE drop, the PRIMARY KEY drop) because those names are the database's, not PormG's. At
  # plan time nothing has executed, so on a rename the catalog still knows the column by its
  # PRE-rename name. `alter_field` was asking for the post-rename one, which meant:
  #
  #   * a renamed column silently lost its UNIQUE / PRIMARY KEY / CHECK drop — the ACTION class this
  #     whole change exists to close, reintroduced by the very fix that made a rename carry its
  #     column change;
  #   * worse, `PositiveIntegerField` → `TextField` under a rename emitted `ALTER COLUMN … TYPE
  #     text` with the stale `>= 0` CHECK still in place. PostgreSQL rejects that outright — the
  #     `alter_field` comment on DROP-before-TYPE says exactly why — so it was a migration that
  #     could not run, where before phase 2 the same pair planned only the RENAME.
  #
  # The fix reads the fact off the delta: `column_delta`'s `old_name` compiles the live side with
  # its own name, and `delta.old_spec.name` is what the renderer looks the constraint up by. These
  # assertions are the intent; the goldens above pin the exact statements. NOTE the mocks are
  # column-aware — with the original always-answering mocks every assertion here passes either way.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "a rename looks its constraints up by the pre-rename column" begin
    # The DROP is emitted at all, and names the constraint the catalog reported for `col`.
    for case in ("rename_and_drop_unique/PG", "rename_and_drop_pk/PG", "rename_and_drop_check/PG")
      steps = PLAN_GOLDEN[case]
      @test [k for (k, _) in steps] == ["Rename field: col2", "Alter field: col2"]
      @test occursin("DROP CONSTRAINT", steps[2][2])
      # The constraint name embeds the PRE-rename column, which is the whole point: a lookup by
      # `col2` returns `nothing` from these mocks and would emit no DROP at all.
      @test occursin("child_t_col", steps[2][2]) || occursin("child_t_pkey", steps[2][2])
      @test !occursin("col2_key", steps[2][2])
    end

    # And the ordering hazard: the CHECK drop precedes the retype, exactly as it does WITHOUT a
    # rename. The non-rename control is asserted beside it so this is a statement about renames
    # being ordinary, not about some DDL merely appearing.
    renamed = PLAN_GOLDEN["rename_and_drop_check/PG"][2][2]
    @test findfirst("DROP CONSTRAINT", renamed).start < findfirst("TYPE text", renamed).start
    # The retype names the NEW column…
    @test occursin("ALTER COLUMN \"col2\" TYPE text", renamed)
    # …while the DROP names the constraint found for the OLD one.
    @test occursin("child_t_col_check", renamed)

    control = PLAN_GOLDEN["positive_to_text/PG"][1][2]
    @test findfirst("DROP CONSTRAINT", control).start < findfirst("TYPE text", control).start
    @test occursin("ALTER COLUMN \"col\" TYPE text", control)

    # On SQLite the same four cases are a rebuild, which needs no catalog name at all — asserted so
    # the engine split is visible rather than assumed.
    for case in ("rename_and_drop_unique/SL", "rename_and_drop_pk/SL", "rename_and_drop_check/SL")
      @test [k for (k, _) in PLAN_GOLDEN[case]] == ["Rename field: col2", "Alter table: child_t"]
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Two renamed-and-altered columns on one SQLite table plan ONE rebuild, and it EXECUTES
  #
  # SQLite alters a column by recreating the table, and the recreation is registered under one key
  # per table — while `_configure_order_dict_migration_plan` overwrites a key IN PLACE, keeping the
  # position of the FIRST registration. The recreation copies by the DESIRED column names, so it can
  # only run after every `RENAME COLUMN` on that table. Get that ordering wrong and the plan reads
  # plausibly and then fails at migrate time with "no such column".
  #
  # `_plan_column_change!` therefore deletes and re-registers the entry, moving it to the end — the
  # same delete-and-reinsert `_add_new_field` performs so that its `ADD COLUMN`s all precede the
  # rebuild. Two review passes shaped this: the first flagged that the collision existed at all
  # (phase 2 widened the trigger from "the FK definition changed" to "any non-empty delta"), and I
  # answered it with a plan-time refusal; the second showed the refusal was ORDER-DEPENDENT —
  # `colect_addition` is a `Set`, so a rename co-occurring with a new NOT NULL column planned
  # correctly or raised depending on field-name hash order. Relocating is deterministic AND makes the
  # case correct, which is why the refusal is gone. It also closes what #150 documented as
  # unsupported.
  #
  # ASSERTED BY EXECUTION, against a real SQLite file, because that is the only oracle that can tell
  # a correctly-ordered plan from a plausible one: the plan is applied and the resulting table is
  # interrogated. A marker mock cannot do this — it would only re-state the plan text back.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "two renamed-and-altered columns on one SQLite table execute in order" begin
    mktempdir() do dir
      pool = SQLiteConnectionPool(joinpath(dir, "golden507reorder.sqlite"); pool_size = 1)
      try
        fetch(pool, """CREATE TABLE "child_t" (
                         "id" INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE NOT NULL,
                         "a1" TEXT(40) NOT NULL,
                         "b1" TEXT(40) NOT NULL)""")
        fetch(pool, """INSERT INTO "child_t" ("id", "a1", "b1") VALUES (1, '7', '9')""")

        settings = PormG.Configuration.Settings()
        settings.change_db = true
        declared = Models.Model("child_t"; id = Models.IDField(),
                                a2 = Models.IntegerField(), b2 = Models.IntegerField())
        live = Models.Model("child_t"; id = Models.IDField(),
                            a1 = Models.CharField(max_length = 40), b1 = Models.CharField(max_length = 40))
        current_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
          :child_t => Dict{Symbol, Union{Bool, PormGModel}}(:model => declared, :exist => false))

        answer, io = mktemp()
        write(io, "1\n1\n")      # two prompts: "the first candidate" each time
        close(io)
        plan = open(answer) do stdin_file
          redirect_stdin(stdin_file) do
            redirect_stdout(devnull) do
              Migrations.get_migration_plan(PormGModel[live], current_schema, pool, settings;
                                            interactive = true)
            end
          end
        end

        steps = collect(keys(plan[:child_t]))
        # ONE rebuild, and it is LAST — after both renames.
        @test count(==("Alter table: child_t"), steps) == 1
        @test steps[end] == "Alter table: child_t"
        @test count(k -> startswith(k, "Rename field:"), steps) == 2

        # THE ORACLE: apply it. `PRAGMA foreign_key_check` is skipped because it is a probe rather
        # than DDL (the runner treats it separately).
        for (_, sql) in plan[:child_t]
          for stmt in split(sql, ";")
            trimmed = strip(stmt)
            isempty(trimmed) && continue
            startswith(uppercase(trimmed), "PRAGMA FOREIGN_KEY_CHECK") && continue
            fetch(pool, String(trimmed))
          end
        end

        cols = sort(string.((fetch(pool, """PRAGMA table_info("child_t")""") |> DataFrame).name))
        @test cols == ["a2", "b2", "id"]
        # …and the row survived the recreation with its values intact, which is what makes this a
        # test of the ORDER rather than of "some SQL ran".
        rows = fetch(pool, """SELECT "id", "a2", "b2" FROM "child_t" """) |> DataFrame
        @test nrow(rows) == 1
        @test rows[1, :a2] == 7 && rows[1, :b2] == 9
      finally
        PormG.ConnectionPool.close_pool!(pool)
      end
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Renderer coverage: every slot a delta can carry reaches a statement
  # Decision 1 of phase 2 deleted `alter_field`'s `IMPLEMENTED` allowlist and its "not implemented"
  # warning, on the grounds that the slot set is closed by type. That is only true if every slot
  # actually renders — so this walks `COLUMN_DELTA_SLOTS` (the constant `column_delta` itself
  # iterates, not a copy of it) and CALLS the renderer for each.
  #
  # Phase 1's version of this guard compared emitted symbols against a hand-transcribed copy of the
  # allowlist. `:generated` was ON that list, so membership passed while the call raised a
  # `FieldError` — green theater that a real invocation caught in minutes.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "every column-delta slot has a renderer branch" begin
    base = column_spec(Models.IntegerField(null = true), GPG507; name = "col")

    # One (new_spec, old_spec) pair per slot, differing in THAT SLOT ONLY, plus the substring the
    # rendered statement must contain. Built by hand rather than from field pairs so a single slot
    # can be moved in isolation — a field pair would usually move two.
    with(spec::ColumnSpec; kwargs...) = ColumnSpec(
      get(kwargs, :name, spec.name), get(kwargs, :type, spec.type),
      get(kwargs, :nullable, spec.nullable), get(kwargs, :primary_key, spec.primary_key),
      get(kwargs, :unique, spec.unique), get(kwargs, :default, spec.default),
      get(kwargs, :reference, spec.reference), get(kwargs, :checks, spec.checks),
      get(kwargs, :identity, spec.identity), get(kwargs, :raw, spec.raw))

    cases = Dict{Symbol, Tuple{ColumnSpec, String}}(
      :type        => (with(base; type = CText(), raw = "text"), "TYPE"),
      :nullable    => (with(base; nullable = false), "SET NOT NULL"),
      :primary_key => (with(base; primary_key = true), "ADD PRIMARY KEY"),
      :unique      => (with(base; unique = true), "ADD UNIQUE"),
      :default     => (with(base; default = LiteralDefault(7)), "SET DEFAULT"),
      :checks      => (with(base; checks = CheckKind[NonNegativeCheck()]), "ADD CHECK"),
      :identity    => (with(base; identity = ColumnIdentity(true, false, false)), "ADD GENERATED"),
    )

    # `:reference` is the ONE slot with no branch, and that absence is the #498 fix rather than a
    # gap: a FOREIGN KEY is not part of a column ALTER, so the planner renders it as DROP + ADD
    # CONSTRAINT off this same slot. Asserted below, not merely excused.
    const_planned = Set([:reference])

    # The completeness check. Derived from `COLUMN_DELTA_SLOTS` so a slot added to
    # `COLUMN_DELTA_COMPARATORS` without a case here FAILS rather than going unnoticed.
    @test Set(keys(cases)) ∪ const_planned == Set(COLUMN_DELTA_SLOTS)
    @test length(COLUMN_DELTA_SLOTS) == length(COLUMN_DELTA_COMPARATORS)

    for (slot, (new_spec, expected)) in cases
      delta = ColumnDelta(new_spec, base, [slot])
      # `IntegerField` is a stand-in for the declared field: only the TEXT comes from it, and only
      # for `:type`. No exception and no warning — the renderer is the oracle for what it can say.
      sql = @test_logs min_level = Logging.Warn Dialect.alter_field(
        GPG507, "child_t", "col", Models.IntegerField(), delta)
      @test occursin(expected, sql)
      # And the delta really is minimal: one slot in, one statement out.
      @test count(!isempty, split(strip(sql), '\n')) == 1
    end

    # The reference slot: no ALTER, and the constraint action instead.
    ref = ForeignKeyRef("parent_t", "Parent_t", "id", nothing)
    ref_delta = ColumnDelta(with(base; reference = ref), base, [:reference])
    @test @test_logs(min_level = Logging.Warn,
                     Dialect.alter_field(GPG507, "child_t", "col", Models.IntegerField(), ref_delta)) == ""
    @test _fk_constraint_action(ref_delta) === :add

    # An empty delta renders nothing at all — which is what makes an unchanged column cost no plan
    # step, and what the rename path relies on for "RENAME COLUMN and nothing else".
    @test Dialect.alter_field(GPG507, "child_t", "col", Models.IntegerField(), ColumnDelta(base, base, Symbol[])) == ""
  end

  # ───────────────────────────────────────────────────────────────────────────
  # The closed slot set is enforced, not just documented
  # `ColumnDelta`'s constructor validates every facet against `COLUMN_DELTA_SLOTS`. This is what
  # replaced the renderer's runtime warning: a typo'd slot is a loud error at the delta rather than
  # a fragment that silently never renders.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "a delta cannot carry a slot the IR does not define" begin
    spec = column_spec(Models.IntegerField(), GPG507; name = "col")
    @test isempty(ColumnDelta(spec, spec, Symbol[]))
    @test !isempty(ColumnDelta(spec, spec, [:type]))
    # The old vocabulary is exactly what must NOT be accepted any more — `:null`, `:generated` and
    # `:to` were the field-attribute names phase 1's adapter produced.
    for bogus in (:null, :generated, :to, :max_length, :db_index, :nonsense)
      err = nothing
      try
        ColumnDelta(spec, spec, [bogus])
      catch e
        err = e
      end
      @test err isa PormG.InvalidMigrationError
      @test occursin(string(bogus), PormG.error_message(err))
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # One foreign-key decision, over specs
  # `_fk_constraint_action` is the single answer to "what happened to this column's FOREIGN KEY?".
  # It replaced `_fk_definition_changed` (three field reads) and, before that, two mirrored XOR
  # guards that between them could not express `:repoint` at all (#498).
  # ───────────────────────────────────────────────────────────────────────────
  @testset "the constraint decision is stated once, over specs" begin
    plain    = column_spec(Models.BigIntegerField(null = true), GPG507; name = "col")
    keyed    = column_spec(_g_declared_fk(), GPG507; name = "col")
    live     = column_spec(_g_live_fk(), GPG507; name = "col")
    other    = column_spec(_g_declared_fk(_g_other_parent()), GPG507; name = "col")
    setnull  = column_spec(_g_declared_fk(; on_delete = Models.SET_NULL), GPG507; name = "col")
    noconstr = column_spec(_g_declared_fk(; db_constraint = false), GPG507; name = "col")

    # All four outcomes.
    @test _fk_constraint_action(keyed, plain)   === :add
    @test _fk_constraint_action(plain, live)    === :drop
    @test _fk_constraint_action(other, live)    === :repoint
    @test _fk_constraint_action(keyed, live)    === :none

    # A changed referential action is a repoint (#498) — the constraint has to be re-issued, because
    # PostgreSQL cannot alter it in place.
    @test _fk_constraint_action(setnull, live)  === :repoint
    # ...but an EQUIVALENT one is not. `PROTECT` renders `RESTRICT` and `DO_NOTHING` renders
    # `NO ACTION`, the same clause `nothing` renders, so neither pair is a change. This is the fold
    # `_fk_definition_changed` needed `Models._fk_on_delete_equal` for; the IR gets it by storing
    # the RENDERED clause.
    protect  = column_spec(_g_declared_fk(; on_delete = Models.PROTECT), GPG507; name = "col")
    restrict = column_spec(_g_live_fk(on_delete = "RESTRICT"), GPG507; name = "col")
    @test _fk_constraint_action(protect, restrict) === :none
    nothing_od = column_spec(_g_live_fk(on_delete = nothing), GPG507; name = "col")
    donothing  = column_spec(_g_declared_fk(; on_delete = Models.DO_NOTHING), GPG507; name = "col")
    @test _fk_constraint_action(donothing, nothing_od) === :none

    # `db_constraint = false` is not consulted as a flag: such a key simply has no reference, so a
    # flip lands as `:drop` and its inverse as `:add` (#503/#408).
    @test _fk_constraint_action(noconstr, live) === :drop
    @test _fk_constraint_action(live, noconstr) === :add
    @test _fk_constraint_action(noconstr, plain) === :none

    # THE DELETION PATH: `nothing` on the new side. The column is going away, so a constraint on it
    # is `:drop` — and a column that never had one is still `:none`.
    @test _fk_constraint_action(nothing, live)  === :drop
    @test _fk_constraint_action(nothing, plain) === :none

    # And the delta-shaped spelling agrees with the two-spec one for every pair above, since it is
    # the same function with one argument.
    for (new_spec, old_spec) in ((keyed, plain), (plain, live), (other, live), (keyed, live))
      delta = ColumnDelta(new_spec, old_spec, column_delta(new_spec, old_spec))
      @test _fk_constraint_action(delta) === _fk_constraint_action(new_spec, old_spec)
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # The #69 fail-safe, now expressed as a spec rather than a symbol
  # A schema diff must never answer "equal" because something threw. Phase 2 needs SPECS on the
  # failure path (the actions read them), so an uncompilable side degrades to a `CUnsupported`
  # marker instead of returning a bare `[:type]`. Two properties are load-bearing.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "an uncompilable column reports CHANGED, and two of them still differ" begin
    good = column_spec(Models.IntegerField(), GPG507; name = "col")
    bad  = Migrations._degraded_spec(Models.IntegerField(), "<uncompilable:new>"; name = "col")
    bad2 = Migrations._degraded_spec(Models.IntegerField(), "<uncompilable:old>"; name = "col")

    # Against a column that DID compile, the answer is `:type` — exactly what the pre-phase-2
    # fail-safe returned, which is why plan text does not move on this path.
    @test column_delta(bad, good) == [:type]
    @test column_delta(good, bad) == [:type]

    # THE FAIL-OPEN GUARD: two sides that both failed must still compare unequal. A single shared
    # marker would make them equal, the delta empty, and the column silently unplanned — the one
    # outcome a schema diff may never have.
    @test bad != bad2
    @test column_delta(bad, bad2) == [:type]

    # A degraded FK keeps its PRESENCE, so `:add`/`:drop` stay right, while its unresolvable target
    # compares unequal to any real one — a constraint that may have moved is re-issued, not assumed
    # intact.
    bad_fk = Migrations._degraded_spec(_g_declared_fk(), "<uncompilable:new>"; name = "col")
    live   = column_spec(_g_live_fk(), GPG507; name = "col")
    plain  = column_spec(Models.BigIntegerField(null = true), GPG507; name = "col")
    @test _fk_constraint_action(bad_fk, plain) === :add
    @test _fk_constraint_action(bad_fk, live)  === :repoint
    @test _fk_constraint_action(plain, bad_fk) === :drop

    # A ManyToManyField is not a column. `column_spec` refuses it outright...
    @test_throws PormG.InvalidMigrationError column_spec(
      Models.ManyToManyField(_g_parent()), GPG507; name = "col")
    # ...and the degraded form reports no reference for one, which is strictly safer than the
    # pre-phase-2 `_fk_constraint_action`: `sManyToManyField` carries a `.to` but NO
    # `db_constraint` slot, so `hasfield(typeof(f), :to) && f.db_constraint` raised a `FieldError`
    # on the same input.
    m2m = Migrations._degraded_spec(Models.ManyToManyField(_g_parent()), "<uncompilable:old>"; name = "col")
    @test m2m.reference === nothing
    @test _fk_constraint_action(nothing, m2m) === :none
  end

  # ───────────────────────────────────────────────────────────────────────────
  # ExpressionDefault renders, so #496 is an addition to the compiler and not to the renderer
  # `column_spec` cannot produce one yet — no `PormGField` has a slot that spells a database-side
  # expression — so a hand-built delta is the only way to reach the branch. It exists because #496
  # (a `db_default` slot) is exactly what makes it reachable, and an unrendered variant would then
  # silently fall through to DROP DEFAULT.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "a database-side expression default is emitted verbatim" begin
    base = column_spec(Models.DateTimeField(null = true), GPG507; name = "col")
    expr = ColumnSpec(base.name, base.type, base.nullable, base.primary_key, base.unique,
                      ExpressionDefault("now()"), base.reference, base.checks, base.identity, base.raw)
    sql = @test_logs min_level = Logging.Warn Dialect.alter_field(
      GPG507, "child_t", "col", Models.DateTimeField(null = true),
      ColumnDelta(expr, base, [:default]))
    @test occursin("SET DEFAULT now()", sql)
    # Not quoted as a literal — that is the whole difference from `LiteralDefault("now()")`, which
    # would (correctly) emit `SET DEFAULT 'now()'`.
    @test !occursin("'now()'", sql)

    lit = ColumnSpec(base.name, base.type, base.nullable, base.primary_key, base.unique,
                     LiteralDefault("now()"), base.reference, base.checks, base.identity, base.raw)
    lit_sql = Dialect.alter_field(GPG507, "child_t", "col", Models.DateTimeField(null = true), ColumnDelta(lit, base, [:default]))
    @test occursin("SET DEFAULT 'now()'", lit_sql)
  end

end
