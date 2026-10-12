# #1129 item 2 — the ENGINE FACTS the migration code branches on.
#
# The migrations twin of `src/querybuilder/engine_facts.jl`, and the same contract: each thing a
# branch used to decide for two engines at once (`conn isa PormGSQLite ? A : B`) is a function with
# one method per engine and **no `::PormGBackend` fallback**, so a new backend (MySQL, #1130) gets a
# `MethodError` naming the fact it must decide instead of SQLite's table rebuild or PostgreSQL's
# `ALTER`. `test/unit/test_engine_facts.jl` reads this file as part of its registry.
#
# Not here: optional features (`_supports`, the capability table), SQL spelling (`Dialect`), and the
# SQLite `ADD COLUMN` limits in `_add_new_field`, which are reviewed one-engine quirks whose other arm
# is the plain `ADD COLUMN` every engine has.

# A schema change the engine cannot make with `ALTER TABLE` — a column retype, a constraint drop, a
# CHECK, a foreign key — is made by rebuilding the table from the declared model (SQLite's
# twelve-step procedure, `Dialect.rebuild_table`). PostgreSQL alters in place, so its plans carry
# per-slot `ALTER` statements and named constraint DDL instead.
_rebuilds_table(::PormGPostgres) = false
_rebuilds_table(::PormGSQLite) = true

# An index the declaration matches but PormG did not create is ADOPTED by stamping PormG's marker in
# its comment (#29). SQLite has no comment on an index to stamp.
_adopts_indexes(::PormGPostgres) = true
_adopts_indexes(::PormGSQLite) = false

# A renamed model-level index is renamed in place. SQLite has no `ALTER INDEX … RENAME`, so the index
# is dropped and re-created under its new name.
_can_rename_index(::PormGPostgres) = true
_can_rename_index(::PormGSQLite) = false

# The key a model-level index name is unique under, as the catalog stores it: PostgreSQL truncates at
# 63 bytes and compares exactly (PormG quotes every name); SQLite keeps the name and compares it
# case-insensitively.
_composite_name_key(conn::PormGPostgres, name::String)::String = _catalog_index_name(conn, name)
_composite_name_key(conn::PormGSQLite, name::String)::String = lowercase(_catalog_index_name(conn, name))

# The built-in ignore list a connection reads the schema with (`_backend_ignore_tables` adds the
# `unignore_defaults:` entries on top).
_builtin_ignore_tables(::PormGPostgres)::Vector{String} = postgres_ignore_table
_builtin_ignore_tables(::PormGSQLite)::Vector{String} = sqlite_ignore_schema
# … and that list's name, as a refusal names it (#805).
_builtin_ignore_tables_name(::PormGPostgres) = "postgres_ignore_table"
_builtin_ignore_tables_name(::PormGSQLite) = "sqlite_ignore_schema"

# A retype between two types with no implicit cast needs `USING` — the column holds the OLD type until
# it runs, so a CHECK count against it would compare the wrong type (#828). SQLite's rebuild copies
# values through the new column's affinity, so nothing is castless there.
_no_implicit_cast(::PormGPostgres, old::CanonicalType, new::CanonicalType)::Bool = _pg_no_implicit_cast(old, new)
_no_implicit_cast(::PormGSQLite, ::CanonicalType, ::CanonicalType)::Bool = false

# A retype carries a `USING` clause, before which `alter_field` drops the column's expression default
# (#828). SQLite's rebuild has no `USING`.
_retype_has_using(::PormGPostgres, old::CanonicalType, new::CanonicalType)::Bool = _pg_retype_has_using(old, new)
_retype_has_using(::PormGSQLite, ::CanonicalType, ::CanonicalType)::Bool = false

# A lengthless TEXT primary key is what `UUIDField(primary_key = true)` renders, so `inspectdb` emits
# that. On PostgreSQL a uuid key renders `uuid`, and a bare `text` key has no declaration.
_text_key_is_uuid(::PormGPostgres) = false
_text_key_is_uuid(::PormGSQLite) = true

# `inspectdb`: a 64-bit integer column is a `BigIntegerField`. SQLite renders `BigIntegerField` and
# `IntegerField` as the same `INTEGER`, so it emits the plainer one.
_declares_bigint(::PormGPostgres) = true
_declares_bigint(::PormGSQLite) = false

# `inspectdb`: a timestamp without a time zone is declared as one (`type = "TIMESTAMP"`). SQLite stores
# both as text, so it emits the default `DateTimeField`.
_declares_naive_timestamp(::PormGPostgres) = true
_declares_naive_timestamp(::PormGSQLite) = false

# The lossy pre-check for a new primary key counts NULLs as well as duplicates: PostgreSQL's primary
# key implies NOT NULL. SQLite's non-`INTEGER` primary key accepts NULL and its `INTEGER PRIMARY KEY`
# fills one with a rowid, so there a NULL fails only through NOT NULL, `:set_not_null`'s finding.
_pk_precheck_counts_nulls(::PormGPostgres) = true
_pk_precheck_counts_nulls(::PormGSQLite) = false

# The pre-check predicate for a value that would violate a `>= 0` CHECK. SQLite's rebuild copies a
# text `'-5'` into an INTEGER-affinity column as `-5`, so it compares the number the text becomes.
_negative_value_predicate(::PormGPostgres, col::AbstractString)::String = "$col < 0"
_negative_value_predicate(::PormGSQLite, col::AbstractString)::String = "CAST($col AS REAL) < 0"

# The pre-check predicate for a value longer, in bytes, than the bound placeholder `ph`.
_byte_length_predicate(::PormGPostgres, col::AbstractString, ph::AbstractString)::String =
  "octet_length($col) > $(ph)::integer"
_byte_length_predicate(::PormGSQLite, col::AbstractString, ph::AbstractString)::String =
  "length(CAST($col AS BLOB)) > $(ph)"
