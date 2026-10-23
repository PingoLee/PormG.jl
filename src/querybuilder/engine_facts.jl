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

# The engine has no interval type, so PormG computes an interval as an integer (#881, #894) — of
# milliseconds on SQLite, of `_interval_unit_ns` in general: a `DurationField` column orders and
# compares by its integer form, an interval in arithmetic is rewritten over it, and the shapes that form
# cannot express are refused here rather than failing on the server. MySQL has no interval type either
# (#1130): a `DurationField` is a BIGINT of microseconds there.
_interval_as_ms(::PormGPostgres) = false
_interval_as_ms(::PormGSQLite) = true
_interval_as_ms(::PormGMySQL) = true

# The unit of that integer, in nanoseconds: what a duration literal binds as, and what a timestamp
# difference counts. SQLite computes in milliseconds, the precision its stored timestamps carry (#79).
# PostgreSQL never computes an interval as an integer (`_interval_as_ms`); its answer is the
# resolution of its own `interval`, for completeness.
_interval_unit_ns(::PormGPostgres) = 1_000
_interval_unit_ns(::PormGSQLite) = 1_000_000
_interval_unit_ns(::PormGMySQL) = 1_000

# The engine STORES an interval as that integer (#1130: MySQL's `DurationField` is a BIGINT of
# microseconds), so an interval's value is already its integer form: a column needs no conversion, a
# computed one leaves the expression as it is, and every interval — a `Case` over durations, a window
# value — orders and compares as the number it is. SQLite stores the `HH:MM:SS` text, which orders as
# the duration only below 100 hours (#894), so it converts at each edge and refuses an interval with no
# integer form. PostgreSQL never computes an interval as an integer (`_interval_as_ms`).
_stores_interval_as_units(::PormGPostgres) = false
_stores_interval_as_units(::PormGSQLite) = false
_stores_interval_as_units(::PormGMySQL) = true

# The engine stores a date as text, so `date ± x` with an operand PormG cannot type would do
# arithmetic on the text — on SQLite, on its year (#882).
_stores_date_as_text(::PormGPostgres) = false
_stores_date_as_text(::PormGSQLite) = true

# A `BIGINT` day count must be cast to `integer` before it shifts a date: PostgreSQL has
# `date ± integer` but no `date ± bigint`.
_casts_bigint_day_count(::PormGPostgres) = true
_casts_bigint_day_count(::PormGSQLite) = false
# MySQL's `INTERVAL (n) DAY` takes a BIGINT count as it is (measured on 8.4, #1130 phase 2b).
_casts_bigint_day_count(::PormGMySQL) = false

# Whether a declared cast type renders as a cast to TEXT on this engine, so a value compared with it
# is that text, not the type's value: on SQLite `Cast(x, "uuid")` and the network types render
# `CAST(x AS TEXT)` (#929).
_cast_renders_text(::PormGField, ::PormGPostgres) = false
_cast_renders_text(field::PormGField, ::PormGSQLite) = _text_cast_on_sqlite(field)
# MySQL casts a `uuid` to `CHAR(36)`, the text it stores one as (#1270), and refuses a network type
# (`:network_types`), so a value compared with either cast is text, as on SQLite (#1130 phase 2b).
_cast_renders_text(field::PormGField, ::PormGMySQL) = _text_cast_on_sqlite(field)

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
# MySQL's `SUM` of integers is a `DECIMAL` whatever their width, and its `/` keeps the fraction
# (measured on 8.4: `SUM(15) / 2` is `7.5`). A sum the walk names is turned back into the integer
# (`_sums_integers_as_decimal`); one it cannot name is not, so its quotient departs (#1130 phase 2b).
_untyped_sum_departs(::PormGMySQL) = true

# #1310 — the engine picks the meaning of `+`, `-`, `*`, `/` and of an ordering from its operands' own
# types, so arithmetic or a comparison beside a date, a timestamp or an interval needs no type from
# PormG: PostgreSQL resolves `interval * bigint`, `date > date`, or fails at the server when it has no
# operator. An engine that answers `false` computes on what it stores — SQLite on a date's or an
# interval's text (`'00:01:30' * 2` is `0`, #1301), MySQL on the number a date's digits spell — so PormG
# writes that SQL for the type, and an operand the type walk cannot name is refused beside one
# (`_refuse_unnamed_temporal`, `expression_render.jl`).
_types_temporal_operands(::PormGPostgres) = true
_types_temporal_operands(::PormGSQLite) = false
_types_temporal_operands(::PormGMySQL) = false

# `SUM` over an integer is a DECIMAL (MySQL: `SUM(INT)` and `SUM(BIGINT)` alike), so `Dialect.SUM` casts
# it back to the integer the sum of integers means. PostgreSQL widens only `sum(bigint)` to `numeric`,
# which `_sums_bigint` handles; SQLite's sum of integers is an integer.
_sums_integers_as_decimal(::PormGPostgres) = false
_sums_integers_as_decimal(::PormGSQLite) = false
_sums_integers_as_decimal(::PormGMySQL) = true

# #1110 — the widest declared decimal (`Cast(x, "numeric(p, s)")`, an `output_field` naming one) the
# engine hands back WITHOUT applying the declaration, so the read path applies it: the read view records
# the declared `CDecimal(p, s)`, and its parser rounds to `s` and refuses a value too wide for `p`
# (`Dialect._parse_sqlite_decimal`). SQLite reads `NUMERIC(p, s)` as an affinity and returns `100` for
# `numeric(2,0)`; up to `SQLITE_EXACT_DECIMAL_DIGITS` the double it returns is still the exact decimal,
# and a wider declaration stays a width-less computed decimal, unchecked. `0`: the engine applies it.
# PostgreSQL rounds and raises "numeric field overflow" (SQLSTATE 22003). MySQL rounds and clamps an
# overflow to the largest value the type holds, so the read could not tell it from a value that fits.
_unapplied_decimal_width(::PormGPostgres) = 0
_unapplied_decimal_width(::PormGSQLite) = Dialect.SQLITE_EXACT_DECIMAL_DIGITS
_unapplied_decimal_width(::PormGMySQL) = 0

# `Greatest`/`Least` skip a NULL argument natively. SQLite renders the scalar `MAX`/`MIN`, which
# return NULL when any argument is, so PormG rewrites the operands (#844).
_greatest_skips_nulls(::PormGPostgres) = true
_greatest_skips_nulls(::PormGSQLite) = false
# MySQL's `GREATEST`/`LEAST` return NULL when any argument is NULL (measured on 8.4: `GREATEST(1, NULL,
# 3)` is NULL), so the operands are rewritten there too, and MySQL renders its own `GREATEST` over them.
_greatest_skips_nulls(::PormGMySQL) = false

# The engine has no boolean type to cast to (#1130 phase 2c-1, MySQL), so a boolean declaration
# (`Cast(x, "boolean")`, `output_field = "boolean"`) over booleans or integers is `((x) <> 0)` there,
# and refused over anything else (`_mysql_declared_output`). PostgreSQL casts to `boolean`; SQLite's
# declarations take `sqlite_cast_sql`.
_normalizes_boolean_cast(::PormGPostgres) = false
_normalizes_boolean_cast(::PormGSQLite) = false
_normalizes_boolean_cast(::PormGMySQL) = true

# NULL placement is emulated with an `(expr IS NULL)` sort key, because the engine has no
# `NULLS FIRST`/`NULLS LAST` (SQLite before 3.30, #75). The version is the capability table's
# `:nulls_order` row (#1163); the fact is whether this engine falls back when the row says no.
_emulates_nulls_order(::PormGPostgres) = false
_emulates_nulls_order(conn::PormGSQLite) = !_supports(conn, :nulls_order)
# MySQL has no `NULLS FIRST`/`NULLS LAST` at any version (measured on 8.4: a syntax error), so it always
# falls back (#1271). Where the key would hold a projection's alias that a FROM column also names, it
# holds the projection's SQL instead (#1130, `_projection_null_key`), on every engine that emulates.
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
