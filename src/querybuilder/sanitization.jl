
# ── Identifier contract (#394) ────────────────────────────────────────────────────────────────
# Two axes, not one. The user-facing statement is in `docs/src/schema_conventions.md` →
# *Identifier quoting*.
#
#   PHYSICAL names (a table, a column) → ESCAPE-ONLY. They are either pinned by the model author via
#     `db_table`/`db_column` — which are deliberately NOT shape-validated (#59/#50), because naming a
#     table PormG's own conventions could not produce is the entire point of the option — or read out
#     of the database catalog by introspection and round-tripped back into a `db_table`/`db_column`
#     pin by `Model_to_str`. Validating them meant PormG rendered a table with
#     `Dialect._quote_table_ddl`, which escapes and never validates, and then REFUSED to query the
#     table it had just created, because `quote_identifier` validated and never escaped. Doubling `"`
#     is the standard SQL escape on both backends and makes the identifier unterminatable, which is
#     the whole threat; there is nothing else to defend against inside a quoted identifier.
#
#   ALIASES and other query-time names → FAIL-CLOSED. A join alias, a `cjoin_on` alias, a
#     `.with(...)` CTE name and a `values("label" => ...)` SELECT alias are chosen while the query is
#     built, are frequently literals the caller typed, and name nothing that already exists — so
#     there is nothing to be faithful to and every reason to be strict.
#
# Do NOT collapse these back into one function. The split IS the fix: a single rule cannot be both
# permissive enough for a legacy table name and strict enough for a caller-supplied alias.
#
# `\A…\z`, not `^…$`, on both patterns here (#794): PCRE's `$` also matches before a final newline,
# so `^…$` accepted `"driver\n"`. `Dialect._is_json_array_index` is anchored the same way (#779).
const SAFE_IDENTIFIER_PATTERN = r"\A[\p{L}_][\p{L}\p{M}\p{N}_]*\z"

# #394: a JSON path segment is NOT a SQL identifier, and this constant is not duplication for its own
# sake. `_validate_json_key_segments` (build_joins.jl) interpolates a segment UNQUOTED into a path
# literal inside a single-quoted SQL string — PostgreSQL `'{a,b}'`, SQLite `'$.a.b'` — so it has no
# quoting to fall back on and the charset check IS the entire guard there. It is kept separate, with a
# body that merely happens to match the one above, so that relaxing the SQL-identifier rules can never
# widen the JSON guard by accident. If you touch `SAFE_IDENTIFIER_PATTERN`, this one does not move.
const SAFE_JSON_KEY_PATTERN = r"\A[\p{L}_][\p{L}\p{M}\p{N}_]*\z"

function _validate_identifier(identifier::String)::String
    if !occursin(SAFE_IDENTIFIER_PATTERN, identifier)
        # `repr`, so a refused newline or other control character is visible in the message (#794).
        throw(InvalidValueError(  # refusal-value-ok: an identifier the developer wrote (#794)
            "Invalid SQL identifier: $(repr(identifier)). PormG requires a plain identifier here because " *
            "this name is used as a query ALIAS — a join alias, a `.with(...)` CTE name, a " *
            "`cjoin_on` alias, or a `values(\"label\" => ...)` label. A physical table or column may " *
            "carry any spelling; pin it with db_table / db_column instead."))
    end
    return identifier
end

# The escape shared by every physical-identifier path (#394). Doubling is the standard SQL escape on
# both backends and a no-op for every name that does not contain a quote. The DDL side has its own
# copy in `Dialect._quote_table_ddl`, which returns the INNER text because its call sites supply the
# surrounding quotes themselves.
_escape_identifier(name::AbstractString)::String = replace(String(name), "\"" => "\"\"")

"""
Quote a query ALIAS or other query-time name. Fail-closed: rejects anything outside
`SAFE_IDENTIFIER_PATTERN`. For a physical table or column use `safe_table_identifier` /
`safe_column_identifier` instead — validating those would refuse names PormG's own DDL creates (#394).
"""
function quote_identifier(identifier::String, conn)::String
    return "\"$(_validate_identifier(identifier))\""
end

"""
Escape LIKE patterns to prevent wildcard injection
"""
function escape_like_pattern(pattern::String)::String
    # Escape special LIKE characters
    escaped = replace(pattern, "\\" => "\\\\")
    escaped = replace(escaped, "%" => "\\%")
    escaped = replace(escaped, "_" => "\\_")
    return escaped
end

"""
Quote a PHYSICAL table name — escape-only, no charset validation (#394). The query-side mirror of
`Dialect._quote_table_ddl`, so a table PormG can create is a table PormG can address.
"""
function safe_table_identifier(table_name::String, conn)::String
    return "\"$(_escape_identifier(table_name))\""
end

"""
Quote a PHYSICAL column name — escape-only, no charset validation (#394). The column axis of
`safe_table_identifier`; `db_column` carries an arbitrary spelling for the same reason `db_table`
does (#50).
"""
function safe_column_identifier(column_name::String, conn)::String
    return "\"$(_escape_identifier(column_name))\""
end

# Escape-only and WITHOUT a `conn`, for interpolation into a SQL string literal that PostgreSQL then
# re-parses as an identifier — `setval`'s `regclass` argument, `to_regclass`. See
# `_table_ident_literal` in execution_write.jl, which composes this with `_sql_literal`. Lives here so the
# escape rule has exactly one definition on the query side (#394; was execution.jl, #59/#344).
_quote_ident_raw(name::AbstractString)::String = "\"$(_escape_identifier(name))\""
