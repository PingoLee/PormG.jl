# #1129 item 2 — the ENGINE FACTS the query builder branches on.
#
# A branch written `conn isa PormGPostgres ? A : B` decides for two engines at once, and its `else` is
# what a THIRD backend silently gets: SQLite's SQL, PostgreSQL's bind casts, or no refusal. Each fact
# below names the one thing such a branch decided, with one method per engine and **no
# `::PormGBackend` fallback**, so a new backend (MySQL, #1130) gets a `MethodError` naming the fact it
# must decide instead of inheriting another engine's answer. This file is that backend's to-do list.
#
# Not here, deliberately:
# - optional FEATURES a backend has or lacks — the capability table (`_supports`, `src/capabilities.jl`);
# - how a VALUE is written, parsed or bound — `value_repr.jl`;
# - SQL spelling the dialect owns — `Dialect`;
# - one-engine quirks whose other arm is the engine-neutral path — those stay as reviewed
#   `isa PormGSQLite && …` guards, counted in `test/unit/test_engine_branches.jl`.
#
# `test/unit/test_engine_facts.jl` holds the registry: every function here has a PostgreSQL and a
# SQLite method, none for `PormGBackend` or `Any`, and a mock third backend gets a `MethodError`.

# The engine has no interval type, so PormG computes an interval as milliseconds (#881, #894): a
# `DurationField` column orders and compares by its millisecond form, an interval in arithmetic is
# rewritten over it, and the shapes that form cannot express are refused here rather than failing
# on the server.
_interval_as_ms(::PormGPostgres) = false
_interval_as_ms(::PormGSQLite) = true
# MySQL has no interval type either (#1130): until phase 2b spells its millisecond form, a duration in an
# ordering or a comparison renders SQLite's, which MySQL rejects at the server, never a silent answer.
_interval_as_ms(::PormGMySQL) = true

# The engine stores a date as text, so `date ± x` with an operand PormG cannot type would do
# arithmetic on the text — on SQLite, on its year (#882).
_stores_date_as_text(::PormGPostgres) = false
_stores_date_as_text(::PormGSQLite) = true

# A `BIGINT` day count must be cast to `integer` before it shifts a date: PostgreSQL has
# `date ± integer` but no `date ± bigint`.
_casts_bigint_day_count(::PormGPostgres) = true
_casts_bigint_day_count(::PormGSQLite) = false

# Whether a declared cast type renders as a cast to TEXT on this engine, so a value compared with it
# is that text, not the type's value: on SQLite `Cast(x, "uuid")` and the network types render
# `CAST(x AS TEXT)` (#929).
_cast_renders_text(::PormGField, ::PormGPostgres) = false
_cast_renders_text(field::PormGField, ::PormGSQLite) = _text_cast_on_sqlite(field)

# A bound parameter carries an explicit SQL type cast (`$1::bigint`), so the server types an untyped
# literal as PormG means it. SQLite's collector ignores a cast (`add_parameter!(::PormGSQLiteParam)`).
_casts_bind_parameters(::PormGPostgres) = true
_casts_bind_parameters(::PormGSQLite) = false
_casts_bind_parameters(::PormGMySQL) = false   # MySQL.jl binds typed values; `?` takes no cast

# An `INSERT` reports the row it wrote (`RETURNING`). SQLite deliberately does not use it: PormG reads
# the row back out-of-band, because `RETURNING` can hang there for some table shapes (#48).
_insert_returns_rows(::PormGPostgres) = true
_insert_returns_rows(::PormGSQLite) = false

# A bulk statement binds one ARRAY per column (`unnest($n::<type>[])`, #672) rather than one
# parameter per cell, so a chunk's parameter count does not grow with its rows.
_bulk_binds_column_arrays(::PormGPostgres) = true
_bulk_binds_column_arrays(::PormGSQLite) = false

# A pre-allocated id written into a `generated_always` identity needs `OVERRIDING SYSTEM VALUE`.
# SQLite has no identity column to override.
_overrides_generated_identity(::PormGPostgres) = true
_overrides_generated_identity(::PormGSQLite) = false

# Draw `n` primary keys for `bulk_insert(returning = …)` before the rows are written (#671).
_allocate_ids(model, conn::PormGPostgres, pk, n, settings) = _allocate_pg_ids(model, conn, pk, n)
_allocate_ids(model, conn::PormGSQLite, pk, n, settings) = _allocate_sqlite_ids(model, conn, pk, n, settings)

# `get_or_create` runs its get + insert + read-back in one transaction: SQLite has no atomic
# insert-or-read, so the steps are serialized; PostgreSQL's `ON CONFLICT` is atomic on its own.
_serializes_get_or_create(::PormGPostgres) = false
_serializes_get_or_create(::PormGSQLite) = true

# A cascading delete locks every parent row, top-down, before it reads one (#770, #771). SQLite's
# writers are already serialized for the whole transaction, so nothing can change under it.
_locks_cascade_parents(::PormGPostgres) = true
_locks_cascade_parents(::PormGSQLite) = false

# `select_for_update()` takes a real row lock. On SQLite the clause renders `""` (#26), so the guard
# that exists because of the lock itself — no `distinct()` — does not apply. The transaction
# requirement is not one of these: it holds on both engines (#1237).
_locks_rows(::PormGPostgres) = true
_locks_rows(::PormGSQLite) = false
_locks_rows(::PormGMySQL) = true   # InnoDB row locks (#1269)

# #1111, #1034 phase 3 step 2a — a `Sum` over an operand the type walk cannot name may not be the
# integer the operands add up to, so its quotient may keep a fraction an integer quotient drops. Over
# a type the walk names the sum is rendered as one (`_sums_bigint`); over an unnamed one PostgreSQL's
# `sum(bigint)` is a `numeric` (`15 / 2` is `7.5`), where SQLite's sum of integers is an integer. The
# division refusal (`_INTEGER_QUOTIENT_DEPARTURE`) fires on an engine that answers `true`.
_untyped_sum_departs(::PormGPostgres) = true
_untyped_sum_departs(::PormGSQLite) = false

# `SUM` over an integer is a DECIMAL (MySQL: `SUM(INT)` and `SUM(BIGINT)` alike), so `Dialect.SUM` casts
# it back to the integer the sum of integers means. PostgreSQL widens only `sum(bigint)` to `numeric`,
# which `_sums_bigint` handles; SQLite's sum of integers is an integer.
_sums_integers_as_decimal(::PormGPostgres) = false
_sums_integers_as_decimal(::PormGSQLite) = false
_sums_integers_as_decimal(::PormGMySQL) = true

# `Greatest`/`Least` skip a NULL argument natively. SQLite renders the scalar `MAX`/`MIN`, which
# return NULL when any argument is, so PormG rewrites the operands (#844).
_greatest_skips_nulls(::PormGPostgres) = true
_greatest_skips_nulls(::PormGSQLite) = false
# MySQL's `GREATEST`/`LEAST` return NULL when any argument is NULL (its documented rule), so the operands
# are rewritten there too; the `GREATEST` renderer itself is phase 2b's.
_greatest_skips_nulls(::PormGMySQL) = false

# NULL placement is emulated with an `(expr IS NULL)` sort key, because the engine has no
# `NULLS FIRST`/`NULLS LAST` (SQLite before 3.30, #75). The version is the capability table's
# `:nulls_order` row (#1163); the fact is whether this engine falls back when the row says no.
_emulates_nulls_order(::PormGPostgres) = false
_emulates_nulls_order(conn::PormGSQLite) = !_supports(conn, :nulls_order)
# MySQL has no `NULLS FIRST`/`NULLS LAST` at any version (measured on 8.4: a syntax error), so it always
# falls back (#1271).
_emulates_nulls_order(::PormGMySQL) = true

# A list membership (`__@in`) binds the whole list as ONE array parameter (`= ANY($1)`), rather than
# one placeholder per element.
_binds_list_as_array(::PormGPostgres) = true
_binds_list_as_array(::PormGSQLite) = false
_binds_list_as_array(::PormGMySQL) = false   # no array binding: one `?` per element

# A JSON path lookup extracts TEXT (`#>>`), so a value compared with it binds as text and an ordering
# casts it to `numeric`. SQLite's `json_extract` keeps the JSON type, so a number stays a number.
_json_path_extracts_text(::PormGPostgres) = true
_json_path_extracts_text(::PormGSQLite) = false

# What `inspect_query` reports as the `:dialect` and the `:bucketing` of the parameters.
_inspection_dialect(::PormGPostgres) = (:postgresql, :numbered)
_inspection_dialect(::PormGSQLite) = (:sqlite, :positional)
_inspection_dialect(::PormGMySQL) = (:mysql, :positional)
