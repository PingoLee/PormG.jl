# ==============================================================================
# MIGRATION RUNNER
# Logic for applying generated migration plans to the database (migrate).
#
# Lifecycle: prepare → validate → lock → execute → commit/rollback →
#            record status → archive
#
# History table (pormg_migrations) is the canonical runtime source of truth.
# Filesystem archives remain secondary.
# ==============================================================================

import SHA: sha256

# Regex patterns for detecting destructive SQL operations (#728). A heuristic over the SQL text, not
# a parser, and it errs toward flagging: a false positive costs an explicit `destructive = true`, a
# false negative runs a data-losing statement unasked. Hand-edited plans are where it matters most —
# the `Data (pre):` / `Data (post):` steps of `docs/src/migrations/advanced.md` are SQL users write
# themselves (#740), and this guard is its only review.
const _DESTRUCTIVE_PATTERNS = [
  # Any DROP: a DROP command of any object kind (TABLE, INDEX, VIEW, SCHEMA, FUNCTION, SEQUENCE, …,
  # including kinds no list here would name), and the ALTER TABLE sub-clauses `DROP [COLUMN] x` —
  # COLUMN is optional on both engines — and `DROP CONSTRAINT`. It used to list four object kinds,
  # so `DROP VIEW` and `ALTER TABLE t DROP x` passed. The property sub-clauses that are not data
  # loss are removed first, by `_PROPERTY_DROP_CLAUSE`.
  r"\bDROP\s+"i,
  # TRUNCATE with or without TABLE / ONLY; PostgreSQL does not require the keyword. SQLite has no
  # TRUNCATE at all — its spelling is the unqualified DELETE below.
  r"\bTRUNCATE\s+"i,
  # DELETE with no WHERE before the statement ends: TRUNCATE by another name, and SQLite's only
  # spelling of it, so the two engines are guarded alike. UPDATE without WHERE is deliberately NOT
  # flagged — it is the ordinary shape of a backfill, and whether it loses data depends on the SET
  # expression, which no regex can judge.
  r"\bDELETE\s+FROM\b(?:(?!\bWHERE\b)[^;])*(?:;|\z)"i,
]

# `ALTER [COLUMN] <col> DROP NOT NULL | DEFAULT | IDENTITY | EXPRESSION` removes a column PROPERTY,
# not data, and `Dialect.alter_field` emits the first three for ordinary nullability, default and
# identity changes. Anchored on the `ALTER [COLUMN] <col>` that owns the clause, so
# `ALTER TABLE t DROP identity` — dropping a column NAMED identity — still reads as a drop.
const _PROPERTY_DROP_CLAUSE =
  r"\bALTER\s+(?:COLUMN\s+)?(?:\"(?:[^\"]|\"\")*\"|\w+)\s+DROP\s+(?:NOT\s+NULL|DEFAULT|IDENTITY|EXPRESSION)\b"i

# ==============================================================================
# Reading a migration plan file as DATA (#710)
# ==============================================================================

"""
    _read_migration_plan(path) -> Vector{OrderedDict{String,String}}

Read a migration plan file (`pending_migrations.jl`) **as data**: it is parsed, never evaluated.
Before #710 it was `include`d. Its SQL, labels and table names carry live catalog identifiers,
so an index named `x\$(run(…))` executed on the operator's machine at the next `dry_run()` or
`migrate()`. The writer now escapes every string (`Generator._plan_str_literal`). This reader is the
other half. It accepts only the shapes the generator writes, so a file poisoned by an older writer,
or edited by hand, is refused instead of run:

- one `module` holding `import`/`using` lines (never executed) and
- one binding per table, `name = OrderedDict{String, String}(` + `"label" => "sql"` pairs + `)`
  (the untyped constructor is accepted too), where every label and SQL is a plain string literal:
  no `\$` interpolation, no call, no concatenation. A name bound twice is refused, because under
  `include` the second silently replaced the first and that table's statements were lost. A label
  repeated within one dict is refused for the same reason: only its last SQL would survive.

Anything else raises `InvalidMigrationError` naming the line. The entries come back ordered by
binding name, the order the `include`-based reader got from `names(mod, all = true)`. That order
reaches the statement order within each bucket, and therefore the checksum.
"""
function _read_migration_plan(path::AbstractString)::Vector{OrderedDict{String, String}}
  file = basename(path)
  line = 0
  bad(what) = throw(InvalidMigrationError(
    "Migration plan '$file' line $line: $what. A plan file is read as data and never executed: " *
    "only `name = OrderedDict{String, String}(\"label\" => \"\"\"sql\"\"\", …)` entries with plain " *
    "string literals are accepted. Regenerate it with makemigrations()."))
  is_parse_error(x) = x isa Expr && x.head in (:error, :incomplete)

  ast = Meta.parseall(read(path, String); filename = String(path))
  modules = Expr[]
  for node in ast.args
    node isa LineNumberNode && (line = node.line; continue)
    is_parse_error(node) && bad("the file does not parse as Julia")
    (node isa Expr && node.head === :module) || bad("unexpected top-level statement")
    push!(modules, node)
  end
  length(modules) == 1 || bad("expected exactly one `module`, found $(length(modules))")

  entries = Dict{Symbol, OrderedDict{String, String}}()
  for node in modules[1].args[3].args
    node isa LineNumberNode && (line = node.line; continue)
    is_parse_error(node) && bad("the file does not parse as Julia")
    node isa Expr && node.head in (:import, :using) && continue
    (node isa Expr && node.head === :(=) && node.args[1] isa Symbol) ||
      bad("unexpected statement (only `name = OrderedDict(…)` is accepted)")
    name = node.args[1]::Symbol
    # `_` / `___` assign to nothing in Julia, so the `include`-based reader silently lost that
    # table's statements. The generator never writes one (`Generator._plan_binding`).
    all(==('_'), String(name)) && bad("an all-underscore binding holds no value")
    # Under `include` a second binding silently replaced the first, and that table's statements
    # were lost. The generator never writes one: it suffixes a name that would parse to a binding
    # it has already used (`Generator._plan_unique_binding`). So this only fires on a hand edit.
    haskey(entries, name) && bad("`$(name)` is bound twice, so one table's statements would be lost")
    entries[name] = _read_plan_dict(node.args[2], bad)
  end
  return [entries[k] for k in sort!(collect(keys(entries)))]
end

function _read_plan_dict(ex, bad)::OrderedDict{String, String}
  (ex isa Expr && ex.head === :call &&
   (ex.args[1] === :OrderedDict || ex.args[1] == :(OrderedDict{String, String}))) ||
    bad("the value must be an `OrderedDict{String, String}(…)` literal")
  dict = OrderedDict{String, String}()
  for pair in ex.args[2:end]
    (pair isa Expr && pair.head === :call && length(pair.args) == 3 && pair.args[1] === :(=>)) ||
      bad("every entry must be a `\"label\" => \"sql\"` pair")
    label, sql = pair.args[2], pair.args[3]
    for s in (label, sql)
      s isa Expr && s.head === :string && bad("string interpolation (`\$`) is not allowed")
      s isa String || bad("the label and the SQL must be plain string literals")
    end
    # The same loss one level down (#733): a repeated label keeps only the last SQL, so a hand-edited
    # dict silently drops a statement. The generator writes from an `OrderedDict`, so never one.
    haskey(dict, label) && bad("the label $(repr(label)) appears twice, so one of its statements would be lost")
    dict[label] = sql
  end
  return dict
end

# ==============================================================================
# Migration History: checksum, version generation, destructive detection
# ==============================================================================

"""
    MIGRATION_FORMAT_VERSION

Version of PormG's frozen migration **format contract** — the on-disk migration-file layout, the
checksum algorithm, and the `pormg_migrations` tracking-table schema. Every record this engine
writes is stamped with this value (the `format_version` column), and generated migration files
carry it as a `# pormg-migration-format: N` header. It is the single source of truth referenced
wherever the format version is written.

`1` is the contract documented under *Migrations → Format Stability*. Bump this only alongside a
documented forward-migration path; never repurpose an existing version number.
"""
const MIGRATION_FORMAT_VERSION = 1

# The plan-header comment naming the models file a plan was diffed against, when that is not the
# connection's own (#736): `makemigrations(db; models_file = …)` writes it, `migrate` reads it to
# archive the right `_old_models.jl`. A comment, so it is additive within format v1 — the plan is
# read as data and its checksum covers only the ordered SQL. The value is `escape_string`'d, so a
# newline in a path cannot end the comment (#710); `_plan_models_file` unescapes it.
const MODELS_FILE_HEADER = "# pormg-models-file: "
const MODELS_FILE_HEADER_RE = r"^# pormg-models-file: (.*?)\r?$"
# The SHA-256 of that file's bytes when the plan was generated, on the line below it. `migrate`
# snapshots the file only if it still hashes the same: that catches an edit between `makemigrations`
# and `migrate`, and it means a header naming some other file — a `config/secrets.jl` — copies
# nothing into `applied_migrations/` unless its author already knew the contents.
const MODELS_SHA256_HEADER = "# pormg-models-sha256: "
const MODELS_SHA256_HEADER_RE = r"^# pormg-models-sha256: ([0-9a-f]{64})\r?$"

_models_file_digest(path::AbstractString)::String = bytes2hex(SHA.sha256(read(path)))

# The plan-header comment carrying one lossy column change (#803): `makemigrations` classifies it
# from the column's `ColumnDelta`, and `dry_run` / `migrate` need it back — but by then the plan is
# SQL text, which cannot say what the column held before. A comment, so it is additive within format
# v1 and outside the checksum, like the #736 lines above. Tab-separated `key=value` fields, each value
# `escape_string`'d, so a tab or a newline inside a catalog name cannot end the field or the comment
# (#710); unknown keys are ignored on read, so a later field needs no format bump.
const LOSSY_ALTER_HEADER = "# pormg-lossy-alter: "
const LOSSY_ALTER_HEADER_RE = r"^# pormg-lossy-alter: (.*?)\r?$"

function _lossy_alter_header(f::LossyAlter)::String
  fields = Pair{String, Any}["kind" => f.kind, "table" => f.table, "column" => f.column,
                             "old" => f.old_type, "new" => f.new_type]
  f.bound === nothing || push!(fields, "bound" => f.bound)
  f.scale === nothing || push!(fields, "scale" => f.scale)
  # #830: one `member=` per composite column, in order — repeated rather than joined, so no
  # separator inside a column name needs escaping.
  for c in f.columns
    push!(fields, "member" => c)
  end
  if f.references !== nothing
    push!(fields, "ref_table" => f.references[1])
    push!(fields, "ref_column" => f.references[2])
  end
  f.condition === nothing || push!(fields, "condition" => f.condition)
  return LOSSY_ALTER_HEADER * join(("$(k)=$(escape_string(string(v)))" for (k, v) in fields), "\t")
end

"""
    _plan_lossy_alters(plan_path) -> Vector{LossyAlter}

The lossy column changes a plan's header records (#803), in file order; empty for a plan without
any, including every plan written before #803. A line that does not read back — a missing field, an
unknown kind, a bound that is not an integer — raises `InvalidMigrationError`: the finding decides
whether `migrate` may run, so a damaged one is refused rather than dropped.
"""
function _plan_lossy_alters(plan_path::AbstractString)::Vector{LossyAlter}
  found = LossyAlter[]
  isfile(plan_path) || return found
  file = basename(plan_path)
  # `open(...) do`: this loop breaks early, see `_plan_models_file`.
  open(plan_path) do io
    for line in eachline(io)
      startswith(line, "import ") && break
      m = match(LOSSY_ALTER_HEADER_RE, line)
      m === nothing && continue
      push!(found, _parse_lossy_alter_header(m.captures[1], file))
    end
  end
  _refuse_unplanned_conditions(found, plan_path)
  return found
end

# ==============================================================================
# The schema precondition (#739): the plan records the schema it was diffed against
# ==============================================================================

# One plan-header comment per table the plan's diff compared: `makemigrations` writes the
# fingerprint of that table as the live database held it — `absent` for a declared table that did
# not exist yet — and `migrate` refuses the plan when the database it is applied to holds anything
# else. A comment, so it is additive within format v1 and outside the checksum, like the #736 and
# #803 lines above. The fingerprint is hex and the name `escape_string`'d, so neither a tab nor a
# newline in a catalog name can end the field or the comment (#710).
const SCHEMA_TABLE_HEADER = "# pormg-schema-table: "
const SCHEMA_TABLE_HEADER_RE = r"^# pormg-schema-table: (absent|[0-9a-f]{16})\t(.+?)\r?$"
# What counts as an ATTEMPT at such a line: looser than the line itself, so an indented, re-spaced or
# hand-mangled one is refused as damaged instead of skipped — skipping every line would apply the
# plan with no check at all.
const SCHEMA_TABLE_HEADER_LOOSE_RE = r"^\s*#\s*pormg-schema-table\b"
const SCHEMA_TABLE_ABSENT = "absent"

# The version prefix of the serialization below. A change to what it covers changes every
# fingerprint, which refuses every plan generated before it — so bump this with the change, and say
# so in the upgrade log.
const _SCHEMA_FINGERPRINT_VERSION = "pormg-schema-table/1"

# The text a fingerprint is the digest of. Written out term by term, never through `repr` or
# `Base.hash`: it is persisted in a plan file and compared in another process, possibly on another
# Julia version, so it has to mean the same bytes there. The IR structs serialize as their type name
# and fields, so a slot added to one changes the fingerprint — `test_plan_schema_fingerprint.jl` pins
# the exact digest to make that visible.
_fp_term(io::IO, ::Nothing) = print(io, '~')
_fp_term(io::IO, x::AbstractString) = print(io, '"', escape_string(x), '"')
_fp_term(io::IO, x::Union{Bool, Integer, Symbol}) = print(io, x)
function _fp_term(io::IO, x::AbstractVector)
  print(io, '[')
  for (i, v) in enumerate(x)
    i > 1 && print(io, ',')
    _fp_term(io, v)
  end
  print(io, ']')
end
# A literal default holds whatever the reader parsed — a number, a string, a timestamp, bytes — so it
# carries its type beside its value: `0` and `"0"` are different defaults. Each value is written in a
# form its own package does not get to change: not `repr`, which for a `ZonedDateTime` is TimeZones'
# to decide. The readers normalize a timestamp to UTC (`_literal_default`), so its UTC wall time is
# the whole of it.
_fp_literal(io::IO, v::AbstractString) = _fp_term(io, v)
_fp_literal(io::IO, v::AbstractVector{UInt8}) = print(io, bytes2hex(v))
_fp_literal(io::IO, v::ZonedDateTime) = print(io, Dates.format(DateTime(v, Dates.UTC), dateformat"yyyy-mm-ddTHH:MM:SS.sss"))
_fp_literal(io::IO, v) = print(io, string(v))
function _fp_term(io::IO, d::LiteralDefault)
  print(io, "LiteralDefault(", nameof(typeof(d.value)), ':')
  _fp_literal(io, d.value)
  print(io, ')')
end
function _fp_term(io::IO, x::Union{CanonicalType, ColumnDefault, CheckKind, ColumnIdentity, ForeignKeyRef,
                                   LiveComposite, LiveCheck})
  T = typeof(x)
  print(io, nameof(T), '(')
  for (i, f) in enumerate(fieldnames(T))
    i > 1 && print(io, ',')
    print(io, f, '=')
    _fp_term(io, getfield(x, f))
  end
  print(io, ')')
end
# Every field but `raw`: the rendered type text is how the catalog happened to spell the type, and
# `type` already carries what it means. `name` is kept — unlike `==` on `ColumnSpec`, which leaves
# renames to the planner — because a renamed column is a different schema for a plan to run on.
function _fp_term(io::IO, s::ColumnSpec)
  print(io, "ColumnSpec(")
  for (i, f) in enumerate(Iterators.filter(!=(:raw), fieldnames(ColumnSpec)))
    i > 1 && print(io, ',')
    print(io, f, '=')
    _fp_term(io, getfield(s, f))
  end
  print(io, ')')
end

"""
    _schema_table_fingerprint(table::Union{LiveTable, Nothing}) -> String

What a plan header records for one table (#739): `"absent"` when the table does not exist, otherwise
the first 16 hex digits of the SHA-256 of the table's serialized [`LiveTable`](@ref) — every column's
[`ColumnSpec`](@ref) but its `raw` text, the single-column indexes, the composite indexes and the
named CHECKs. Columns, indexes and constraints are sorted by name, so the physical column order (which
an SQLite rebuild can change) is not part of it.

Both sides are read by the same `read_live_schema` the drift `check` uses. The fingerprint is
**stricter** than the planner's diff, on purpose: it also covers what the diff treats as equal or
leaves to other passes — the names of indexes and constraints, a CHECK's comment, both axes of a
foreign key's target. A plan's statements name those objects (`DROP INDEX "<name>"`), so a database
that differs in them is not one the plan was written for, even where `makemigrations` would plan
nothing there.
"""
function _schema_table_fingerprint(t::Union{LiveTable, Nothing})::String
  t === nothing && return SCHEMA_TABLE_ABSENT
  io = IOBuffer()
  println(io, _SCHEMA_FINGERPRINT_VERSION)
  print(io, "table "); _fp_term(io, t.name); println(io)
  for name in sort!(collect(keys(t.columns)))
    print(io, "column "); _fp_term(io, t.columns[name]); println(io)
  end
  for name in sort!(collect(keys(t.indexes)))
    print(io, "index "); _fp_term(io, name); print(io, ' '); _fp_term(io, t.indexes[name]); println(io)
  end
  for c in sort(t.composites; by = c -> c.name)
    print(io, "composite "); _fp_term(io, c); println(io)
  end
  for c in sort(t.checks; by = c -> c.name)
    print(io, "check "); _fp_term(io, c); println(io)
  end
  return bytes2hex(sha256(take!(io)))[1:16]
end

"""
    _schema_table_fingerprints(live, scope) -> OrderedDict{String, String}

The header `makemigrations` writes: one fingerprint per table in `scope`, sorted by name — the live
table's when `live` holds it, `"absent"` when it does not.
"""
function _schema_table_fingerprints(live::Vector{LiveTable}, scope)::OrderedDict{String, String}
  by_name = Dict{String, LiveTable}(t.name => t for t in live)
  return OrderedDict{String, String}(name => _schema_table_fingerprint(get(by_name, name, nothing))
                                     for name in sort!(collect(String, scope)))
end

_schema_table_header(name::AbstractString, fingerprint::AbstractString)::String =
  string(SCHEMA_TABLE_HEADER, fingerprint, '\t', escape_string(name))

"""
    _plan_schema_tables(plan_path) -> Union{OrderedDict{String, String}, Nothing}

The schema precondition a plan's header records (#739): table name ⇒ fingerprint, in file order.
`nothing` when the plan has no such line — every plan written before #739, and one whose lines were
deleted on purpose, which is the documented way to apply a plan to a schema it was not generated
from. A line that does not read back, or a table named twice, raises `InvalidMigrationError`: the
precondition decides whether `migrate` may run, so a damaged one is refused rather than dropped.
"""
function _plan_schema_tables(plan_path::AbstractString)::Union{OrderedDict{String, String}, Nothing}
  isfile(plan_path) || return nothing
  file = basename(plan_path)
  bad(what) = throw(InvalidMigrationError(
    "Migration plan '$file': a `$(strip(SCHEMA_TABLE_HEADER))` line $what. Regenerate the plan with makemigrations()."))
  found = OrderedDict{String, String}()
  # `open(...) do`: this loop breaks early, see `_plan_models_file`.
  open(plan_path) do io
    for line in eachline(io)
      startswith(line, "import ") && break
      occursin(SCHEMA_TABLE_HEADER_LOOSE_RE, line) || continue
      m = match(SCHEMA_TABLE_HEADER_RE, line)
      m === nothing && bad("is not `$(SCHEMA_TABLE_HEADER)<16 hex digits or absent><TAB><table>`")
      name = try unescape_string(m.captures[2]) catch; bad("has a table name that does not unescape") end
      haskey(found, name) && bad("names table $(repr(name)) twice")
      found[name] = String(m.captures[1])
    end
  end
  return isempty(found) ? nothing : found
end

"""
    PlanPreconditionError(msg, tables)

Raised by [`migrate`](@ref) when the database no longer holds the schema the pending plan was
generated against (#739). `makemigrations` records a fingerprint of every table its diff compared in
the plan header; `migrate` reads the same tables again and refuses on any difference — once before
the migration lock, so a stale plan fails before any prompt or row count, and again inside it, which
is the check that decides. Either way no plan statement runs and no `failed` row is recorded; a
refusal inside the lock comes after `migrate` has ensured the history table and the configured
extensions, as it does on every call.

`tables` lists each table that differs, as `(table, expected, found)` fingerprints, where
`"absent"` means the table does not exist. A table the plan never compared — one created in the
database after `makemigrations`, outside the models — is not part of the precondition.

This is what stops an old plan from replaying: a `pending_migrations.jl` baked into an earlier
release names the schema *before* its own changes, which a database already past them no longer
holds. To apply a plan anyway, regenerate it against this database with `makemigrations()`, or
delete its `# pormg-schema-table:` lines: a plan without them applies without the check.
"""
struct PlanPreconditionError <: MigrationError
  msg::String
  tables::Vector{NamedTuple{(:table, :expected, :found), Tuple{String, String, String}}}
end

function _precondition_summary(t)::String
  t.expected == SCHEMA_TABLE_ABSENT && return "$(t.table): did not exist when the plan was generated, and now does"
  t.found == SCHEMA_TABLE_ABSENT && return "$(t.table): existed when the plan was generated, and no longer does"
  return "$(t.table): differs from the schema the plan was generated against"
end

function Base.showerror(io::IO, e::PlanPreconditionError)
  print(io, "PlanPreconditionError: ", e.msg)
  for t in e.tables
    print(io, "\n  → ", _precondition_summary(t))
  end
end

"""
    _schema_precondition_drift(connection, settings, recorded) -> Vector

The recorded tables whose live fingerprint is not the one the plan header records, read through
`read_live_schema` with the ignore list `makemigrations` and `check` build. Read-only. On SQLite,
inside `migrate`'s write transaction, the caller binds the transaction's connection with
`with_tx_context`, so the read sees what the transaction sees.
"""
function _schema_precondition_drift(connection::Union{PormGPostgres, PormGSQLite}, settings::PormGSettings,
                                    recorded::AbstractDict{String, String})
  ignore = _with_connection_ignores(_backend_ignore_tables(connection, settings), settings)
  live = read_live_schema(connection; ignore_table = ignore, include_table = collect(String, keys(recorded)))
  by_name = Dict{String, LiveTable}(t.name => t for t in live)
  drift = NamedTuple{(:table, :expected, :found), Tuple{String, String, String}}[]
  for (name, expected) in recorded
    found = _schema_table_fingerprint(get(by_name, name, nothing))
    found == expected || push!(drift, (table = name, expected = expected, found = found))
  end
  return drift
end

_plan_precondition_error(drift, recorded::AbstractDict{String, String})::PlanPreconditionError =
  PlanPreconditionError(
    "The database no longer holds the schema the pending plan was generated against " *
    "($(length(drift)) of $(length(recorded)) recorded table(s) differ), so no statement of the plan was run. " *
    "Run makemigrations() against this database to plan from what it holds, or remove the plan's " *
    "`$(strip(SCHEMA_TABLE_HEADER))` lines to apply it without the check.", drift)

function _check_schema_precondition(connection::Union{PormGPostgres, PormGSQLite}, settings::PormGSettings,
                                    recorded::AbstractDict{String, String})::Nothing
  drift = _schema_precondition_drift(connection, settings, recorded)
  isempty(drift) || throw(_plan_precondition_error(drift, recorded))
  return nothing
end

"""
    _anchor_check_conditions(findings, settings) -> Vector{LossyAlter}

The findings, with each `:add_check` condition kept only when the models file declares that same
CHECK — same table, same name, same condition text (#830). The condition is the one value the
pre-check interpolates into SQL, and the plan is DATA (#710): `dry_run` never executes its
statements, so neither the header nor a statement beside it may decide what SQL the count runs. The
models file is the trusted source the plan was written from, loaded with `makemigrations`' own
loader, and only when the header has a CHECK finding at all.

A condition the models do not declare — a hand-edited header, a table renamed in the same plan, a
models file changed since `makemigrations`, or one that does not load — is not counted. So is every
CHECK of a plan made with `makemigrations(…; models_file = …)` naming another file: the anchor is the
connection's own models file, never a path the plan header names, because loading a file is running
it and the plan is data (#736 only hashes the file it records, for the same reason). Not counted
means the finding keeps its place with no condition (`_finding_countable`), and the database checks
the CHECK when the migration runs, as it did before #830.
"""
function _anchor_check_conditions(findings::Vector{LossyAlter}, settings::PormGSettings)::Vector{LossyAlter}
  any(f -> f.kind === :add_check, findings) || return findings
  declared = Set{Tuple{String, String, String}}()
  try
    schema = _load_current_models(_resolve_models_file(settings, nothing, "the CheckConstraint row count"))
    for entry in values(schema)
      m = get(entry, :model, nothing)
      m isa PormGModel || continue
      for c in Models.declared_check_constraints(m)
        push!(declared, (String(model_table_name(m)), c.name, c.condition))
      end
    end
  catch e
    (e isa InterruptException || e isa StackOverflowError) && rethrow()
    @warn("The models file could not be loaded, so no CheckConstraint is pre-counted; the database still checks each one when the migration runs.",
          exception = e)
  end
  anchored(f) = f.kind !== :add_check || (f.table, f.column, something(f.condition, "")) in declared
  return LossyAlter[anchored(f) ? f :
                    LossyAlter(f.kind, f.table, f.column, f.old_type, f.new_type, f.bound, f.scale, f.rows,
                               f.columns, f.references, nothing)
                    for f in findings]
end

# #830: an `:add_check` finding carries the condition the pre-check interpolates into its
# `SELECT COUNT(*) … WHERE NOT (<condition>)`. That is SQL the developer wrote, and the plan runs it
# as DDL anyway — but the header is outside what `migrate` executes, so a condition is only taken
# from it when the plan's own statements carry the same CHECK: `CHECK (<condition>)` on PostgreSQL,
# `CHECK (<condition> /* pormg:check:… */)` in SQLite's rebuild. A header that does not match was
# edited apart from the plan, and is refused like any other damaged line.
function _refuse_unplanned_conditions(found::Vector{LossyAlter}, plan_path::AbstractString)::Nothing
  checks = filter(f -> f.kind === :add_check, found)
  isempty(checks) && return nothing
  statements, _ = _order_statements(_read_migration_plan(plan_path))
  for f in checks
    pg, sl = "CHECK ($(f.condition))", "CHECK ($(f.condition) /* "
    any(s -> occursin(pg, s) || occursin(sl, s), statements) && continue
    throw(InvalidMigrationError(
      "Migration plan '$(basename(plan_path))': a `$(strip(LOSSY_ALTER_HEADER))` line of kind `add_check` " *
      "names a condition no statement in the plan adds (constraint $(repr(f.column)) on $(repr(f.table))). " *
      "Regenerate the plan with makemigrations()."))
  end
  return nothing
end

function _parse_lossy_alter_header(body::AbstractString, file::AbstractString)::LossyAlter
  bad(what) = throw(InvalidMigrationError(
    "Migration plan '$file': a `$(strip(LOSSY_ALTER_HEADER))` line $what. Regenerate the plan with makemigrations()."))
  fields = Dict{String, String}()
  members = String[]
  for part in split(body, '\t')
    k, sep, v = _partition_first(part, '=')
    sep || bad("has a field without `=`")
    value = try unescape_string(v) catch; bad("has a value that does not unescape") end
    k == "member" ? push!(members, value) : (fields[k] = value)
  end
  for key in ("kind", "table", "column", "old", "new")
    haskey(fields, key) || bad("has no `$key` field")
  end
  kind = Symbol(fields["kind"])
  haskey(LOSSY_ALTER_KINDS, kind) || bad("names an unknown kind `$(fields["kind"])`")
  function int(key)
    haskey(fields, key) || return nothing
    n = tryparse(Int, fields[key])
    n === nothing && bad("has a `$key` that is not an integer")
    return n
  end
  bound, scale = int("bound"), int("scale")
  # The pre-check counts against these, so a kind that needs one and lacks it would count nothing
  # and pass the plan silently — the one outcome a damaged header must not have.
  for key in get(_LOSSY_ALTER_REQUIRED, kind, ())
    (key === :bound ? bound : scale) === nothing && bad("of kind `$kind` has no `$key` field")
  end
  kind === :integer_range && !(bound in (16, 32, 64)) &&
    bad("of kind `integer_range` has a `bound` that is not an integer width (16, 32 or 64)")
  # #830: the constraint kinds count against these instead of a limit — and an absent one would
  # count nothing, so it is refused the same way.
  kind === :add_composite_unique && isempty(members) && bad("of kind `add_composite_unique` has no `member` field")
  references = nothing
  if kind === :add_foreign_key
    (haskey(fields, "ref_table") && haskey(fields, "ref_column")) ||
      bad("of kind `add_foreign_key` has no `ref_table` / `ref_column` field")
    references = (fields["ref_table"], fields["ref_column"])
  end
  kind === :add_check && !haskey(fields, "condition") && bad("of kind `add_check` has no `condition` field")
  return LossyAlter(kind, fields["table"], fields["column"], fields["old"], fields["new"];
                    bound = bound, scale = scale, columns = members, references = references,
                    condition = kind === :add_check ? fields["condition"] : nothing)
end

# The limits each counted kind is compared against (`_precheck_sql`).
const _LOSSY_ALTER_REQUIRED = Dict{Symbol, Tuple{Vararg{Symbol}}}(
  :varchar_length => (:bound,), :integer_range => (:bound,), :byte_length_check => (:bound,),
  :decimal_precision => (:bound, :scale))

# `split(s, '=', limit = 2)` without losing whether there was a separator at all.
function _partition_first(s::AbstractString, c::Char)
  i = findfirst(c, s)
  i === nothing && return (String(s), false, "")
  return (String(s[1:prevind(s, i)]), true, String(s[nextind(s, i):end]))
end

"""
    compute_checksum(sql_content::String) -> String

Compute a SHA-256 hex digest of the SQL content for integrity verification.
"""
function compute_checksum(sql_content::String)::String
  return bytes2hex(sha256(Vector{UInt8}(sql_content)))
end

"""
    generate_version() -> String

Generate a unique migration version string based on timestamp (YYYYMMDDHHmmssSSS).
Includes milliseconds to prevent version collisions for rapid successive migrations.
"""
function generate_version()::String
  return Dates.format(Dates.now(), "yyyymmddHHMMSSsss")
end

"""
    is_destructive(sql::String) -> Bool

Whether `sql` (one statement or several) holds a statement the guard treats as data-losing. That
is what `migrate` refuses to apply non-interactively without `destructive = true`. It flags:

- any `DROP`: a `DROP <object>` command of any kind (`TABLE`, `INDEX`, `VIEW`, `SCHEMA`, `FUNCTION`,
  `SEQUENCE`, …), and `ALTER TABLE … DROP [COLUMN] x` / `DROP CONSTRAINT`. The exceptions are the
  `ALTER [COLUMN] <col> DROP NOT NULL | DEFAULT | IDENTITY | EXPRESSION` sub-clauses, which remove a
  property rather than data;
- `TRUNCATE`, with or without `TABLE`;
- `DELETE FROM` with no `WHERE`: `TRUNCATE` by another name, and SQLite's only spelling of it.

`UPDATE` without `WHERE` is not flagged: that is the ordinary shape of a backfill.

It reads the SQL text and does not parse it, so it errs toward flagging: a string literal or quoted
identifier that reads `drop x` is reported too. A generated `SET DEFAULT 'Drop zone'` is one
example. That costs an explicit `destructive = true`, whereas a missed statement would run unasked
(#728). Literals are deliberately not stripped first, because that would hide the
`EXECUTE 'DROP TABLE ' || t` inside a `DO` block. It also misses a few hand-written spellings:
any `WHERE` excuses a `DELETE`, even `WHERE true`, and a keyword glued to a quoted name or a
comment (`DROP"col"`, `DELETE/**/FROM`) is not seen.
"""
function is_destructive(sql::String)::Bool
  sql = replace(sql, _PROPERTY_DROP_CLAUSE => " ")
  for pattern in _DESTRUCTIVE_PATTERNS
    if occursin(pattern, sql)
      return true
    end
  end
  return false
end

"""
    detect_destructive_actions(statements::Vector{String}) -> Vector{String}

Return the subset of SQL statements that contain destructive operations.
"""
function detect_destructive_actions(statements::Vector{String})::Vector{String}
  return filter(is_destructive, statements)
end

# ==============================================================================
# Migration confirmation gate (destructive guard + interactive prompt)
# ==============================================================================

"""
    DestructiveMigrationError(msg, statements)

Raised when a migration containing destructive operations (DROP TABLE, DROP COLUMN, …) is applied in a
**non-interactive** context (no TTY, or `interactive=false`) without `destructive=true`. Failing loudly
here means CI, `Pkg.test`, and deploy scripts break with an actionable message instead of hanging on
`readline()` or silently skipping the migration.

Reparented from `Exception` to `MigrationError <: PormGError` (#239). Catching
`DestructiveMigrationError` specifically is unaffected; it is merely ALSO catchable as
`MigrationError` / `PormGError`. It keeps its own `showerror` (a more specific method wins).
"""
struct DestructiveMigrationError <: MigrationError
  msg::String
  statements::Vector{String}
  # #803: the plan's `:silent` lossy column changes — ALTERs that apply and change existing values,
  # which take the same opt-in as a DROP. Empty for a plan the regex alone flagged.
  lossy_alters::Vector{LossyAlter}
end

DestructiveMigrationError(msg::AbstractString, statements::Vector{String}) =
  DestructiveMigrationError(String(msg), statements, LossyAlter[])

function Base.showerror(io::IO, e::DestructiveMigrationError)
  print(io, "DestructiveMigrationError: ", e.msg)
  for s in e.statements
    print(io, "\n  → ", length(s) > 120 ? first(s, 120) * "..." : s)
  end
  for f in e.lossy_alters
    print(io, "\n  → ", _lossy_alter_summary(f))
  end
end

# ==============================================================================
# Lossy column changes (#803): the row pre-check and its refusal
# ==============================================================================

"""
    MigrationPrecheckError(msg, findings)

Raised by [`migrate`](@ref) when the pending plan changes a column or adds a constraint in a way
existing rows cannot survive — a `SET NOT NULL` over rows that hold NULL, a `VARCHAR(n)` shorter than
values already stored, an integer too narrow for them, duplicates under a new UNIQUE, rows with no
parent under a new foreign key — or in a way PostgreSQL cannot apply at all. `findings` lists each [`LossyAlter`](@ref), with `rows` counted.

Nothing has been written when it is raised: the pre-check counts before the migration starts.
`destructive = true` does not bypass it, because no opt-in can make those rows fit. Fix the data (or
the models file) and run `makemigrations()` again; a hand-written backfill or `USING` added to the
plan is the other way through, described in the migrations workflow guide.

Like [`DestructiveMigrationError`](@ref), it is raised only where nobody can be asked: at an
interactive terminal the same plan logs the findings and `migrate` returns `:declined`.
"""
struct MigrationPrecheckError <: MigrationError
  msg::String
  findings::Vector{LossyAlter}
end

function Base.showerror(io::IO, e::MigrationPrecheckError)
  print(io, "MigrationPrecheckError: ", e.msg)
  for f in e.findings
    print(io, "\n  → ", _lossy_alter_summary(f))
  end
end

_precheck_ph(::PormGPostgres, i::Int)::String = "\$$(i)"
_precheck_ph(::PormGSQLite, ::Int)::String = "?"

const _INT_RANGE = Dict(16 => (typemin(Int16), typemax(Int16)),
                        32 => (typemin(Int32), typemax(Int32)),
                        64 => (typemin(Int64), typemax(Int64)))

"""
    _precheck_sql(conn, finding) -> Union{Nothing, Tuple{String, Vector{Any}}}

The `SELECT COUNT(*)` that counts the rows a `:rows`-class finding would fail on, or `nothing` for a
finding of another class. The table and column are catalog names read back from the plan header,
so they go through `Dialect._quote_table_ddl` exactly as every plan statement's identifiers do; the
bounds are always bound parameters, never interpolated.

Each predicate is the condition the engine itself refuses on, so the count is the number of rows the
ALTER would fail on — not an estimate:

- `:set_not_null` — `IS NULL`. Neither engine backfills an existing NULL from a declared default
  (PostgreSQL's `SET NOT NULL` checks the rows as they are; SQLite's rebuild copies the NULL).
- `:varchar_length` — the length with trailing spaces trimmed: PostgreSQL silently truncates an
  over-long value whose excess is all spaces.
- `:integer_range` — the value as it would round, against the new width's range.
- `:decimal_precision` — the value rounded to the new scale, which can carry into a digit the new
  precision does not have (`9.999` into `numeric(3,2)`).
- `:add_not_null` — every row: the column does not exist yet, and a NOT NULL column with no default
  has nothing to put in any of them (#829).
- `:add_unique`, `:add_composite_unique` — every row in a group of two or more equal non-NULL
  values (tuples), since a NULL is distinct from every value on both engines (#830).
- `:add_primary_key` — the same duplicates, plus the NULLs on PostgreSQL, which makes a key column
  NOT NULL. SQLite's non-`INTEGER` primary key accepts NULL, and its `INTEGER PRIMARY KEY` fills one
  with a rowid, so NULLs fail it only through NOT NULL — which is `:set_not_null`'s finding.
- `:add_check` — the rows whose condition is FALSE. A NULL condition passes a CHECK on both engines,
  and `NOT (NULL)` is NULL, so they are not counted either.
- `:add_foreign_key` — the non-NULL values no parent row holds.
- `:text_cast` — the non-NULL values the target type does not accept (#828), asked of the server's own
  input function with `pg_input_is_valid` — the parser the `USING` cast runs, typmod included, so an
  overflow counts too. That function is PostgreSQL 16+; on an older `server_version` (an `Int` in
  `server_version_num` form) see `_text_cast_fallback`.
"""
function _precheck_sql(conn::Union{PormGPostgres, PormGSQLite}, f::LossyAlter;
                       server_version::Union{Nothing, Int} = nothing)::Union{Nothing, Tuple{String, Vector{Any}}}
  lossy_alter_class(f) === :rows || return nothing
  table = Dialect._quote_table_ddl(f.table)
  q(name) = "\"$(Dialect._quote_table_ddl(name))\""
  col = q(f.column)
  ph(i) = _precheck_ph(conn, i)
  f.kind === :add_not_null && return ("SELECT COUNT(*) AS n FROM \"$table\"", Any[])
  # The rows in duplicate groups, as one integer on both engines (PostgreSQL's `SUM` of a count is
  # `numeric`).
  duplicates(cols) = "SELECT COALESCE(SUM(n), 0) AS n FROM (SELECT COUNT(*) AS n FROM \"$table\" WHERE " *
                     join(("$c IS NOT NULL" for c in cols), " AND ") * " GROUP BY $(join(cols, ", ")) " *
                     "HAVING COUNT(*) > 1) AS pormg_duplicates"
  if f.kind === :add_unique || (f.kind === :add_primary_key && conn isa PormGSQLite)
    return ("SELECT CAST(($(duplicates([col]))) AS BIGINT) AS n", Any[])
  elseif f.kind === :add_primary_key
    return ("SELECT CAST(($(duplicates([col]))) + (SELECT COUNT(*) FROM \"$table\" WHERE $col IS NULL) AS BIGINT) AS n", Any[])
  elseif f.kind === :add_composite_unique
    return ("SELECT CAST(($(duplicates([q(c) for c in f.columns]))) AS BIGINT) AS n", Any[])
  elseif f.kind === :add_check
    # Interpolated, and only here — and only a condition the models file declares: `dry_run` and
    # `migrate` pass every finding through `_anchor_check_conditions`, which strips any other, and
    # `_finding_countable` keeps a stripped one from reaching this line.
    f.condition === nothing && throw(InvalidMigrationError("No CheckConstraint condition to count with."))
    return ("SELECT COUNT(*) AS n FROM \"$table\" WHERE NOT ($(f.condition))", Any[])
  elseif f.kind === :add_foreign_key
    parent, key = f.references
    return ("SELECT COUNT(*) AS n FROM \"$table\" AS pormg_child WHERE pormg_child.$col IS NOT NULL " *
            "AND NOT EXISTS (SELECT 1 FROM $(q(parent)) AS pormg_parent " *
            "WHERE pormg_parent.$(q(key)) = pormg_child.$col)", Any[])
  elseif f.kind === :text_cast
    pred, params = something(server_version, _PG_INPUT_IS_VALID) >= _PG_INPUT_IS_VALID ?
      ("pg_input_is_valid(CAST($col AS text), $(ph(1))) IS FALSE", Any[f.new_type]) :
      _text_cast_fallback(col, parse_canonical_type(f.new_type, conn))
    return ("SELECT COUNT(*) AS n FROM \"$table\" WHERE $col IS NOT NULL AND $pred", params)
  end
  pred, params = if f.kind === :set_not_null
    "$col IS NULL", Any[]
  elseif f.kind === :non_negative_check
    # SQLite: the rebuild copies a text `'-5'` into an INTEGER-affinity column as `-5`, so compare
    # the number it becomes — a text value never compares `< 0` there. Over-counts one shape: junk
    # like `'-5abc'` casts to -5 but stays text in the new column (and passes the CHECK), so it is
    # a refusal the data did not strictly need — the safe direction. PostgreSQL only reaches this
    # with a numeric old type (a text one is `:no_implicit_cast`), so the plain comparison is exact.
    (conn isa PormGSQLite ? "CAST($col AS REAL) < 0" : "$col < 0"), Any[]
  elseif f.kind === :byte_length_check
    (conn isa PormGPostgres ? "octet_length($col) > $(ph(1))::integer" :
                              "length(CAST($col AS BLOB)) > $(ph(1))"), Any[f.bound]
  elseif f.kind === :varchar_length
    # #28: an `inet` is measured as the text the ALTER writes — `abbrev`, the printed form (see
    # `Dialect._postgres_retype_using`) — not as its text cast, which adds the mask (`/32`) and would
    # refuse a value that fits.
    measured = conn isa PormGPostgres && parse_canonical_type(f.old_type, conn) isa CInet ?
      "abbrev($col)" : "CAST($col AS text)"
    "char_length(rtrim($measured)) > $(ph(1))::integer", Any[f.bound]
  elseif f.kind === :integer_range
    lo, hi = _INT_RANGE[f.bound]
    "round(CAST($col AS numeric)) NOT BETWEEN $(ph(1))::numeric AND $(ph(2))::numeric", Any[Int(lo), Int(hi)]
  elseif f.kind === :decimal_precision
    # `NaN` is a value a constrained `numeric(p, s)` accepts, so it is not a failing row.
    "CAST($col AS numeric) <> 'NaN'::numeric AND " *
    "abs(round(CAST($col AS numeric), $(ph(1))::integer)) >= power(10::numeric, $(ph(2))::integer)",
      Any[f.scale, f.bound]
  else
    throw(InvalidMigrationError("No pre-check is defined for the lossy-ALTER kind `$(f.kind)`."))
  end
  return ("SELECT COUNT(*) AS n FROM \"$table\" WHERE $pred", params)
end

# `pg_input_is_valid` arrived in PostgreSQL 16 (`server_version_num` 160000); PormG's floor is 11.
const _PG_INPUT_IS_VALID = 160000

# PostgreSQL 11–15 has no `pg_input_is_valid`, so the `:text_cast` count falls back to the grammar of
# the target type's input function, as an anchored regex over the text (#828). Exact for an integer
# (and its range), a numeric (and its precision) and a boolean; close for a float and a UUID, whose
# input functions accept a few rare spellings these do not (a hex float; a UUID hyphenated at odd
# places is accepted, unbalanced braces too). A value wrongly refused costs a hand-written step on a
# pre-16 server; one wrongly accepted still fails the ALTER, which rolls back. Dates, timestamps and JSON have
# no such grammar (`'Jan 5 2020'`, a `DateStyle`-dependent order, nested JSON), and neither do `inet`
# and `cidr` (#28: the server takes classful short forms such as `10.1` that PormG's own parser
# refuses, so that parser is not the server's grammar), so there every non-NULL value counts as
# unverifiable: such a retype over a populated table needs PostgreSQL 16.
const _TEXT_CAST_RE = (
  int = raw"^\s*[+-]?[0-9]+\s*$",
  float = raw"^\s*([+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?|[+-]?(inf|infinity|nan))\s*$",
  numeric = raw"^\s*([+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?|nan)\s*$",
  bool = raw"^\s*(t|tr|tru|true|y|ye|yes|on|1|f|fa|fal|fals|false|n|no|of|off|0)\s*$",
  uuid = raw"^\{?[0-9a-f]{4}(-?[0-9a-f]{4}){7}\}?$",
  nan = raw"^\s*nan\s*$",
)

function _text_cast_fallback(col::AbstractString, target::CanonicalType)::Tuple{String, Vector{Any}}
  t = "CAST($col AS text)"
  if target isa _IntType
    lo, hi = _INT_RANGE[_int_bits(target)]
    # `CASE`, not `AND`: PostgreSQL does not promise to evaluate the regex before the cast.
    return ("CASE WHEN $t ~ \$1 THEN CAST($t AS numeric) NOT BETWEEN \$2::numeric AND \$3::numeric ELSE true END",
            Any[_TEXT_CAST_RE.int, Int(lo), Int(hi)])
  elseif target isa CDecimal && _whole_digits(target) !== nothing
    # NaN fits any `numeric(p, s)`. Matched with the same `\s` the grammar allows (`btrim` would
    # strip spaces only, and a tab-padded `NaN` would reach `abs()`), and bound like every other
    # pattern here, so `standard_conforming_strings` cannot change what it means.
    return ("CASE WHEN $t ~* \$1 THEN $t !~* \$4 AND " *
            "abs(round(CAST($t AS numeric), \$2::integer)) >= power(10::numeric, \$3::integer) ELSE true END",
            Any[_TEXT_CAST_RE.numeric, _decimal_scale(target), _whole_digits(target), _TEXT_CAST_RE.nan])
  elseif target isa Union{CFloat64, CDecimal, CBool, CUUID}
    re = target isa CFloat64 ? _TEXT_CAST_RE.float : target isa CDecimal ? _TEXT_CAST_RE.numeric :
         target isa CBool ? _TEXT_CAST_RE.bool : _TEXT_CAST_RE.uuid
    return ("$t !~* \$1", Any[re])
  end
  return ("true", Any[])
end

# Does the live table still have this column? A plan header can outlive what it describes — the plan
# was edited by hand, or the #81 path re-archives a plan whose ALTER already ran — and a finding
# about a column that is gone is stale, not a reason to refuse.
function _live_column_exists(conn::PormGPostgres, table::AbstractString, column::AbstractString)::Bool
  rows = fetch(conn, """
    SELECT count(*) AS n FROM pg_attribute
     WHERE attrelid = to_regclass(quote_ident(\$1)) AND attname = \$2
       AND attnum > 0 AND NOT attisdropped
    """, [String(table), String(column)]) |> DataFrame
  return nrow(rows) > 0 && rows[1, :n] > 0
end

_live_column_exists(conn::PormGSQLite, table::AbstractString, column::AbstractString)::Bool =
  String(column) in _sqlite_table_xinfo_columns(conn, table)

function _live_table_exists(conn::PormGPostgres, table::AbstractString)::Bool
  rows = fetch(conn, "SELECT count(*) AS n FROM pg_class WHERE oid = to_regclass(quote_ident(\$1))",
               [String(table)]) |> DataFrame
  return nrow(rows) > 0 && rows[1, :n] > 0
end

_live_table_exists(conn::PormGSQLite, table::AbstractString)::Bool =
  !isempty(_sqlite_table_xinfo_columns(conn, table))

# Does the live schema still describe what the finding is about? For a change to an existing column,
# the column is there; for a column the plan ADDS (#829), the table is there and the column is NOT —
# a header naming a column that already exists was applied already (the #81 re-archive) or edited.
# A table-level constraint (#830) names no single column: a CHECK applies while its table is there,
# a composite while every member is.
function _finding_applies(conn::Union{PormGPostgres, PormGSQLite}, f::LossyAlter)::Bool
  f.kind === :add_not_null &&
    return _live_table_exists(conn, f.table) && !_live_column_exists(conn, f.table, f.column)
  f.kind === :add_check && return _live_table_exists(conn, f.table)
  f.kind === :add_composite_unique && return all(c -> _live_column_exists(conn, f.table, c), f.columns)
  return _live_column_exists(conn, f.table, f.column)
end

# Can the count run against the schema as it is now? A foreign key's parent may be one this same plan
# creates, or renames (the reference names the NEW table, the catalog still has the old one), or
# whose key column it renames. Then there is nothing to count against, and the finding is kept
# uncounted: the database checks the key when the migration runs, as it did before #830.
#
# A CHECK whose condition is not declared in the models (`_anchor_check_conditions`) is the other
# uncountable case: there is no trusted condition to count with.
function _finding_countable(conn::Union{PormGPostgres, PormGSQLite}, f::LossyAlter)::Bool
  f.kind === :add_check && return f.condition !== nothing
  f.kind === :add_foreign_key && return _live_column_exists(conn, f.references[1], f.references[2])
  return true
end

"""
    _precheck_lossy_alters(conn, findings; timeouts) -> Vector{LossyAlter}

The findings with `rows` counted for each `:rows`-class one (#803), read-only. A finding whose column
the live table no longer has is dropped with a warning (see `_live_column_exists`). The count is
advisory in one direction only: rows can change between it and the ALTER, and an ALTER that then
fails still rolls the whole migration back.

On PostgreSQL the counts run in one `READ ONLY` transaction whose `lock_timeout` is `lock_wait` (and
whose `statement_timeout` is the caller's), because they run BEFORE the migration lock: an instance
booting while another holds the table for its own `ALTER` must wait no longer than `lock_wait` says,
as it would on the advisory lock. Each count sits behind a savepoint, so one that fails because the
column vanished meanwhile (the other instance's plan renamed it) is dropped as stale instead of
aborting the rest; any other failure is raised.

`timeouts` is untyped because `_MigrationTimeouts` is defined further down this file. SQLite has no
lock to wait on, so it takes and ignores them.
"""
function _precheck_lossy_alters(conn::PormGSQLite, findings::Vector{LossyAlter};
                                timeouts = nothing)::Vector{LossyAlter}
  return LossyAlter[c for c in (_precheck_one(conn, f) for f in findings) if c !== nothing]
end

function _precheck_lossy_alters(conn::PormGPostgres, findings::Vector{LossyAlter};
                                timeouts = nothing)::Vector{LossyAlter}
  timeouts === nothing && (timeouts = _migration_timeouts())
  checked = LossyAlter[]
  # READ COMMITTED explicitly: the stale re-probe below must see a rename another instance just
  # committed, which a session default of REPEATABLE READ would hide behind this transaction's snapshot.
  _, leased = with_transaction(conn, "BEGIN READ ONLY ISOLATION LEVEL READ COMMITTED;")
  local rollback_error = nothing
  try
    # Values are `Int`s PormG formatted (`_migration_timeouts`), never caller text.
    with_transaction(conn, "SET LOCAL lock_timeout = '$(timeouts.lock_wait_ms)ms';", conn = leased)
    timeouts.statement_timeout_ms === nothing ||
      with_transaction(conn, "SET LOCAL statement_timeout = '$(timeouts.statement_timeout_ms)ms';", conn = leased)
    # Under the transaction context, so every `fetch` below runs on `leased` and leaves it leased.
    # A `fetch(...; conn = leased)` would not: an explicit `conn` is treated as outside any
    # transaction and handed back to the pool when the statement finishes — mid-transaction (#139).
    Configuration.with_tx_context(conn, leased) do
      # #828: the `:text_cast` count depends on the server's version; read once, and only for one.
      version = any(f -> f.kind === :text_cast, findings) ?
        Int(DataFrame(fetch(conn, "SELECT current_setting('server_version_num')::integer AS v"))[1, :v]) : nothing
      for f in findings
        with_transaction(conn, "SAVEPOINT pormg_precheck;", conn = leased)
        counted = try
          _precheck_one(conn, f; server_version = version)
        catch
          # Did the column vanish while the count waited (another instance's plan renamed it)?
          # If this recovery itself fails the transaction is unusable, and the count's own error
          # is the one worth reporting.
          gone = try
            with_transaction(conn, "ROLLBACK TO SAVEPOINT pormg_precheck;", conn = leased)
            !_finding_applies(conn, f)
          catch
            false
          end
          gone || rethrow()
          _warn_stale_lossy_alter(f)
          nothing
        end
        counted === nothing || push!(checked, counted)
      end
    end
    with_transaction(conn, "COMMIT;", conn = leased, release_conn = false)
  catch e
    try
      with_transaction(conn, "ROLLBACK;", conn = leased, release_conn = false)
    catch rollback_err
      rollback_error = rollback_err
    end
    rethrow(e)
  finally
    finalize_transaction_connection!(conn, leased; rollback_error = rollback_error)
  end
  return checked
end

# One finding, counted — or `nothing` when its column is gone. On PostgreSQL it runs inside
# `_precheck_lossy_alters`' transaction context, so the plain `fetch`es use its connection.
function _precheck_one(conn::Union{PormGPostgres, PormGSQLite}, f::LossyAlter;
                      server_version::Union{Nothing, Int} = nothing)::Union{Nothing, LossyAlter}
  if !_finding_applies(conn, f)
    _warn_stale_lossy_alter(f)
    return nothing
  end
  if !_finding_countable(conn, f)
    @info(f.kind === :add_check ?
            "This CheckConstraint's condition is not declared in the models file as the plan records it, so its rows are not pre-counted; the database checks them when the migration runs." :
            "A foreign key's parent is not in the database yet (this plan creates or renames it), so its rows are not pre-counted; the database checks them when the migration runs.",
          finding = _lossy_alter_summary(f))
    return f
  end
  q = _precheck_sql(conn, f; server_version = server_version)
  q === nothing && return f
  counted = fetch(conn, q[1], q[2]) |> DataFrame
  n = nrow(counted) == 0 ? 0 : Int(something(counted[1, :n], 0))
  if n > 0 && f.kind === :text_cast && server_version !== nothing && server_version < _PG_INPUT_IS_VALID &&
     parse_canonical_type(f.new_type, conn) isa Union{CDate, CDateTime, CJSON}
    @warn("This PostgreSQL server is older than 16, so it cannot check which values would parse as the new type; every non-NULL value is counted as failing. Convert the column on PostgreSQL 16+, or with a hand-written step.",
          finding = _lossy_alter_summary(f))
  end
  return _with_rows(f, n)
end

_warn_stale_lossy_alter(f::LossyAlter) =
  @warn("The plan's header records a lossy change to a column the database does not have (or adds a column it already has), so it is ignored. The plan was edited by hand, or another instance already applied it; if you edited it, regenerate it with makemigrations().",
        finding = _lossy_alter_summary(f))

# What to do instead, for a kind whose way out is not "fix the data" — appended once per kind present.
const _LOSSY_ALTER_HINTS = Dict{Symbol, String}(
  :add_not_null => "A new NOT NULL column needs a value for the rows already there: declare a `default` " *
                   "(or `db_default`), or add the column with `null = true`, fill it, then make it NOT NULL " *
                   "in a later migration.")

# The findings `migrate` must refuse whatever the caller opts into: rows that would fail, and changes
# PostgreSQL cannot apply as planned.
_failing_alters(findings::Vector{LossyAlter})::Vector{LossyAlter} =
  filter(f -> lossy_alter_class(f) === :refused ||
              (lossy_alter_class(f) === :rows && something(f.rows, 0) > 0), findings)

# The findings that apply and change data — the destructive guard's opt-in covers them.
_silent_alters(findings::Vector{LossyAlter})::Vector{LossyAlter} =
  filter(f -> lossy_alter_class(f) === :silent, findings)

"""
    _refuse_failing_alters(findings; interactive) -> Bool

The pre-check's verdict for `migrate`: `true` to go on, `false` to decline (a terminal: the findings
are logged and `migrate` returns `:declined`). Throws [`MigrationPrecheckError`](@ref) where nobody
can be asked — the same terminal rule as `_confirm_migration`, so automation fails loudly rather
than being told about a failure in a log it may not read.
"""
function _refuse_failing_alters(findings::Vector{LossyAlter}; interactive::Bool)::Bool
  failing = _failing_alters(findings)
  isempty(failing) && return true
  msg = "The plan has $(length(failing)) change(s) the database would refuse on existing rows, or " *
        "cannot apply at all. Nothing was applied. Fix the data (or the models file) and run " *
        "makemigrations() again; `destructive = true` does not bypass this." *
        join((" " * _LOSSY_ALTER_HINTS[k] for k in unique(f.kind for f in failing) if haskey(_LOSSY_ALTER_HINTS, k)))
  (interactive && (stdin isa Base.TTY)) || throw(MigrationPrecheckError(msg, failing))
  @error(_emsg("\e[31m$msg\e[0m"))
  for f in failing
    @error("  → $(_lossy_alter_summary(f))")
  end
  return false
end

"""
    _confirm_migration(has_destructive, destructive, destructive_stmts; interactive) -> Bool

Resolve the destructive guard and interactive confirmation for `migrate`. A prompt is only possible on a
real terminal, so `can_prompt = interactive && (stdin isa Base.TTY)` — this is what keeps `migrate()` from
ever blocking on `readline()` in CI, `Pkg.test`, or a deploy script (even when `interactive=true`, the
default).

Returns `true` to proceed, `false` to abort quietly (the caller then `return nothing`). Throws
[`DestructiveMigrationError`](@ref) when a destructive plan is refused in a non-interactive context, so
automation fails loudly instead of hanging or silently skipping.
"""
function _confirm_migration(has_destructive::Bool, destructive::Bool,
                            destructive_stmts::Vector{String}; interactive::Bool,
                            lossy_alters::Vector{LossyAlter} = LossyAlter[])::Bool
  can_prompt = interactive && (stdin isa Base.TTY)

  # Destructive guard: a destructive plan requires an explicit `destructive=true` opt-in. Since #803
  # `lossy_alters` — the plan's `:silent` column changes — count too, and `has_destructive` already
  # includes them; a PostgreSQL plan can be destructive through them alone, with no DROP in it.
  if has_destructive && !destructive
    parts = String[]
    isempty(destructive_stmts) || push!(parts, "$(length(destructive_stmts)) destructive operation(s)")
    isempty(lossy_alters) || push!(parts, "$(length(lossy_alters)) column change(s) that alter existing values")
    msg = "Migration contains $(join(parts, " and ")). Pass `destructive=true` to confirm."
    # Non-interactive (CI / no TTY / interactive=false): fail loudly so automation cannot
    # silently skip — and never reach the blocking readline() below.
    can_prompt || throw(DestructiveMigrationError(msg, destructive_stmts, lossy_alters))
    @error(_emsg("\e[31m$msg\e[0m"))
    for s in destructive_stmts
      display_s = length(s) > 120 ? first(s, 120) * "..." : s
      @error("  → $display_s")
    end
    for f in lossy_alters
      @error("  → $(_lossy_alter_summary(f))")
    end
    return false
  end

  # Interactive confirmation — only when a human can actually answer (real TTY).
  if can_prompt
    if has_destructive
      @info(_emsg("\e[31m⚠ This migration contains DESTRUCTIVE operations (a DROP, a TRUNCATE, a DELETE with no WHERE, or a column change that alters existing values).\e[0m"))
    end
    @info(_emsg("\e[33mBefore applying the migrations, make sure to back up your database.\e[0m"))
    print(_emsg("\e[31mAre you sure you want to apply the migrations? (yes/no): \e[0m"))
    response = strip(lowercase(readline()))
    if !(response in ["yes", "y"])
      @info("Migrations were not applied.")
      return false
    end
  end

  return true
end

# Frozen format-v1 primitive (see test/unit/test_migration_format_v1.jl). Retained for format
# stability, but no longer auto-invoked: `mark_applied` used to call this to *fabricate* a checksum
# when the caller supplied neither `sql_content` nor `checksum`. A fabricated digest can never be
# verified against the real migration, silently defeating drift detection (issue #81), so
# `mark_applied` now refuses that path instead of fabricating.
function _manual_checksum(version::String, name::String)::String
  return bytes2hex(sha256(Vector{UInt8}("manual:" * version * ":" * name)))
end

# ==============================================================================
# Bootstrap: init_migrations() — ensure the history table exists
# ==============================================================================

"""
    init_migrations(connection::Union{PormGPostgres, PormGSQLite})

Create the pormg_migrations history table if it does not already exist.
`migrate()`, `mark_applied`, `mark_failed` and `remove_migration_record` call it themselves; it can
also be invoked explicitly for bootstrapping. `status()` does not: it is read-only, and reports a
missing table instead of creating one.
"""
function init_migrations(connection::PormGPostgres)
  ddl = Dialect.create_migrations_table(connection)
  fetch(connection, ddl)
  _ensure_format_version_column(connection)
  nothing
end

function init_migrations(connection::PormGSQLite)
  ddl = Dialect.create_migrations_table(connection)
  fetch(connection, ddl)
  _ensure_format_version_column(connection)
  _ensure_canonical_applied_at(connection)
  nothing
end

"""
    _ensure_canonical_applied_at(connection::PormGSQLite)

Idempotently rewrite `applied_at` rows written in SQLite's own `YYYY-MM-DD HH:MM:SS` form into
PormG's canonical timestamp text (#570).

Tables created before #570 defaulted the column to `datetime('now')`, and `CREATE TABLE IF NOT
EXISTS` never revisits an existing default — SQLite cannot alter one in place short of a table
rebuild. New rows are covered by `_record_migration`, which writes the column explicitly; this is
the one-time repair for the rows that predate it.

Probe first, then write — the `_ensure_format_version_column` shape. A database with nothing to
repair (every database after its first pass) is answered by one read of a small table and never
asked for a write: SQLite opens the write transaction at `UPDATE` statement start even when the
WHERE matches nothing, so an unconditional UPDATE would turn a no-op `migrate()` on a read-only
file into an error. SQLite only: the PostgreSQL column is a real `timestamp`, whose
representation is its type.
"""
function _ensure_canonical_applied_at(connection::PormGSQLite)
  legacy = DataFrame(fetch(connection, Dialect.legacy_applied_at_exists_sql(connection)))
  nrow(legacy) > 0 && fetch(connection, Dialect.repair_migrations_applied_at_sql(connection))
  nothing
end

"""
    _ensure_format_version_column(connection)

Idempotently add the `format_version` column to a `pormg_migrations` table that predates it.

Brand-new tables already include the column via `create_migrations_table`; this only matters for
databases initialized by a pre-`format_version` PormG release, where `CREATE TABLE IF NOT EXISTS`
is a no-op and the column must be added in place. Existing rows backfill to `1` via the column
DEFAULT — they were written under the v1 format contract.

The column is probed first (`migrations_table_info_sql`) so the `ALTER` runs only when genuinely
absent. SQLite *requires* this — re-adding a column is a hard error — and on PostgreSQL it avoids a
routine `NOTICE: column already exists` on every `init_migrations` call (which `migrate`, `status`,
and `mark_applied` all trigger). The PostgreSQL `ALTER` additionally keeps `IF NOT EXISTS` to stay
safe against a concurrent migration adding the column between this probe and the `ALTER`.
"""
function _ensure_format_version_column(connection::Union{PormGPostgres, PormGSQLite})
  cols = DataFrame(fetch(connection, Dialect.migrations_table_info_sql(connection)))
  has_col = nrow(cols) > 0 && "format_version" in string.(cols.name)
  has_col || fetch(connection, Dialect.add_format_version_column_sql(connection))
  nothing
end

function init_migrations(settings::PormGSettings)
  init_migrations(settings.connections)
end

function init_migrations(db::String; config::Dict{String,PormGSettings} = config)
  settings = config[db]
  init_migrations(settings)
end

# ==============================================================================
# History table queries
# ==============================================================================

# A history read, optionally on a connection the caller already holds — the migration transaction's
# own, which is how the SQLite #81 guard reads inside `BEGIN IMMEDIATE` (#737). Through
# `with_transaction(…; conn)`, the idiom `sqlite_foreign_keys_enabled` uses, and NOT `fetch(…; conn)`:
# outside a `run_in_transaction` context `fetch` releases the connection it ran on when it finishes
# (`await_result`'s `finally`), so it would hand the open transaction's handle back to the pool.
function _history_rows(connection::Union{PormGPostgres, PormGSQLite}, sql::String; conn = nothing)::DataFrame
  conn === nothing && return DataFrame(fetch(connection, sql))
  rows, _ = with_transaction(connection, sql; conn = conn)
  return DataFrame(rows)
end

"""
    _migrations_table_exists(connection; conn = nothing) -> Bool

Check whether the pormg_migrations table already exists in the database. With `conn`, the read runs
on that already-leased connection (see `_history_rows`).
"""
function _migrations_table_exists(connection::PormGPostgres; conn = nothing)::Bool
  df = _history_rows(connection, Dialect.migrations_table_exists_sql(connection); conn = conn)
  return nrow(df) > 0 && df[1, 1] == true
end

function _migrations_table_exists(connection::PormGSQLite; conn = nothing)::Bool
  df = _history_rows(connection, Dialect.migrations_table_exists_sql(connection); conn = conn)
  return nrow(df) > 0 && df[1, 1] > 0
end

"""
    _get_applied_migrations(connection; conn = nothing) -> Vector{NamedTuple}

Fetch all migration records from the history table, ordered by version.
"""
function _get_applied_migrations(connection::Union{PormGPostgres, PormGSQLite}; conn = nothing)
  if !_migrations_table_exists(connection; conn = conn)
    return NamedTuple[]
  end
  df = _history_rows(connection, Dialect.select_all_migrations_sql(connection); conn = conn)
  # Convert DataFrame rows to NamedTuples for uniform access
  return [NamedTuple(row) for row in eachrow(df)]
end

"""
    _latest_applied(connection; conn = nothing) -> Union{NamedTuple, Nothing}

The most-recently-applied migration record — the `status='applied'` row with the greatest
`version` — or `nothing` when nothing has been applied yet.

Idempotency guard for `migrate()` (issue #81). `migrate()` mints a fresh timestamp `version` on
every run, so re-apply detection must key on migration **content** (the checksum), never the
version. We deliberately compare against the *latest applied* record only, not the full history,
so a legitimate drop-then-re-add — whose regenerated SQL is byte-identical to the original add —
is still applied, while a stale `pending_migrations.jl` left behind by a post-commit archive
failure is recognised as already-applied and skipped instead of being destructively re-run.

The whole record rather than its checksum because `migrate` reports the matched row's `version` in
its [`MigrationResult`](@ref) (#737).
"""
function _latest_applied(connection::Union{PormGPostgres, PormGSQLite}; conn = nothing)
  latest = nothing
  for r in _get_applied_migrations(connection; conn = conn)
    # records come back ordered by version ASC, so the last applied row we see is the newest.
    if r[:status] == "applied"
      latest = r
    end
  end
  return latest
end

"""
    _latest_applied_checksum(connection; conn = nothing) -> Union{String, Nothing}

The checksum of `_latest_applied`'s record, or `nothing` when nothing has been applied yet.
"""
function _latest_applied_checksum(connection::Union{PormGPostgres, PormGSQLite}; conn = nothing)::Union{String, Nothing}
  latest = _latest_applied(connection; conn = conn)
  latest === nothing && return nothing
  return String(latest[:checksum])
end

"""
    _get_live_table_names(connection) -> Vector{String}

Retrieve the list of user table names from the live database schema.
Used for drift detection.

The same tables the live readers enumerate (#730): partitions, extension-owned tables and SQLite
virtual/shadow tables are not user tables PormG could own, so they are not counted here either.
(`information_schema.tables` reports a partition as a `BASE TABLE`.)
"""
function _get_live_table_names(connection::PormGPostgres)::Vector{String}
  sql = """
    SELECT c.relname AS table_name
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind = 'r' AND n.nspname = 'public'
      $(_PG_OWNABLE_TABLE_FILTER)
    ORDER BY c.relname;"""
  df = DataFrame(fetch(connection, sql))
  return String[string(r[:table_name]) for r in eachrow(df)]
end

_get_live_table_names(connection::PormGSQLite)::Vector{String} = sort!(_sqlite_user_table_names(connection))

"""
    _record_migration(connection, version, name, checksum, sql_content, status, is_destructive; conn)

Insert a migration record into the history table within an existing transaction connection.

Every value is bound, never interpolated (#846): `version` and `name` arrive from the public repair
ops and `sql_content` is the whole plan's SQL. The statement is `Dialect.insert_migration_record_sql`,
which on SQLite also writes `applied_at` explicitly (#570).

Releases the connection iff it acquired one here (`conn === nothing`). A caller that passes `conn`
owns it (the migration transaction) and frees it itself; without this, the fire-and-forget call
sites (`mark_applied` / `mark_failed` and the lifecycle failure paths) would take a write connection
and never return it on success, a slow pool leak.
"""
function _record_migration(pool::Union{PormGPostgres, PormGSQLite}, version::String, name::String,
                           checksum::String, sql_content::String, status::String, is_destr::Bool;
                           conn = nothing)
  # SQLite stores the bound `Bool` as the integer `1`/`0` the column has always held.
  params = Any[version, name, checksum, sql_content, status, is_destr, MIGRATION_FORMAT_VERSION]
  with_transaction(pool, Dialect.insert_migration_record_sql(pool);
                   conn = conn, release_conn = conn === nothing, params = params)
end

"""
    _update_migration_status(connection, version, new_status; conn)

Update the status of an existing migration record. Both values are bound (#846), and the connection
is released iff it was acquired here, as in `_record_migration`.
"""
function _update_migration_status(pool::Union{PormGPostgres, PormGSQLite}, version::String, new_status::String;
                                  conn = nothing)
  with_transaction(pool, Dialect.update_migration_status_sql(pool);
                   conn = conn, release_conn = conn === nothing, params = Any[new_status, version])
end

# ==============================================================================
# Status API
# ==============================================================================

"""
    MigrationStatus

Structured result from `status()`. Contains applied migrations, pending files,
failed migrations, and drift signals about the migration history (see `status`).

A `failed` row whose plan a later run applied — a later `applied` row with the same checksum — is in
`superseded`, not in `failed` (#739): a plan runs in one transaction, so the failure wrote nothing,
and the retry that succeeded resolved it. `failed` holds only the failures nothing has resolved.
"""
struct MigrationStatus
  applied::Vector{NamedTuple}    # Migrations recorded as 'applied' in DB
  failed::Vector{NamedTuple}     # 'failed' rows no later apply of the same checksum resolved
  superseded::Vector{NamedTuple} # 'failed' rows a later 'applied' row of the same checksum resolved (#739)
  pending::Bool                  # Whether a pending_migrations.jl file exists
  has_history_table::Bool        # Whether pormg_migrations table exists
  drift_signals::Vector{String}  # Informational messages about potential drift
  data_steps::Vector{NamedTuple} # run_once steps recorded in pormg_migrations_data (#740), oldest first
end

function Base.show(io::IO, s::MigrationStatus)
  println(io, "Migration Status:")
  println(io, "  History table: ", s.has_history_table ? "✓ exists" : "✗ not initialized (run init_migrations)")
  println(io, "  Applied: ", length(s.applied), " migration(s)")
  if !isempty(s.failed)
    println(io, _emsg(io, "  \e[31mFailed: $(length(s.failed)) migration(s)\e[0m"))
    for m in s.failed
      println(io, "    - v", m[:version], " ", m[:name])
    end
  end
  isempty(s.superseded) ||
    println(io, "  Superseded failures: ", length(s.superseded), " (a later run applied the same plan)")
  isempty(s.data_steps) || println(io, "  Data steps: ", length(s.data_steps), " applied (run_once)")
  println(io, "  Pending file: ", _emsg(io, s.pending ? "\e[33myes (review and run migrate)\e[0m" : "none"))
  if !isempty(s.drift_signals)
    println(io, _emsg(io, "  \e[33mDrift signals:\e[0m"))
    for d in s.drift_signals
      println(io, "    ⚠ ", d)
    end
  end
  if !isempty(s.applied)
    println(io, "\n  Applied migrations:")
    for m in s.applied
      println(io, "    [", m[:version], "] ", m[:name], " (", m[:status], ", ", 
              m[:is_destructive] in [true, 1] ? "destructive" : "safe", ")")
    end
  end
end

"""
    status(connection, settings) -> MigrationStatus

Report migration status: applied, failed, pending, and drift signals.

The drift signals are about the migration **history**, not the schema: a missing history table,
failed records, a pending plan beside applied history, and recorded migrations over a database with
no user tables at all.

A failed record counts only while nothing has resolved it (#739). Failures do not block the next
`migrate`, and a plan runs in one transaction on both engines, so a `failed` row means nothing was
applied; once a later run applies the same plan (the same checksum), the failure moves to
`superseded` and its drift signal clears. A failure no later apply matches stays in `failed`.

`data_steps` lists the [`run_once`](@ref) steps recorded in `pormg_migrations_data` (#740), oldest
first — empty until the first one runs.

`status()` does not compare the live schema with the models — that is
`check(db; kinds = [:schema_drift])`. It is read-only, and does not create the history table.
"""
function status(connection::Union{PormGPostgres, PormGSQLite}, settings::PormGSettings)::MigrationStatus
  # #683: every folder-reading entry point refuses a `register_connection` entry first — its
  # `db_def_folder` is a label, and `joinpath` would read `./dynamic_connection/` instead.
  Configuration._require_folder_backed(settings, "status")
  has_table = _migrations_table_exists(connection)
  
  applied = NamedTuple[]
  failed = NamedTuple[]
  superseded = NamedTuple[]
  drift_signals = String[]
  
  if has_table
    all_records = _get_applied_migrations(connection)
    for (i, r) in enumerate(all_records)
      if r[:status] == "applied"
        push!(applied, r)
      elseif r[:status] == "failed"
        # Records come back in version order, so "later" is "after it in this list" (#739).
        resolved = any(l -> l[:status] == "applied" && isequal(l[:checksum], r[:checksum]),
                       @view all_records[i+1:end])
        push!(resolved ? superseded : failed, r)
      end
    end
  else
    push!(drift_signals, "History table pormg_migrations does not exist. Run init_migrations() to bootstrap.")
  end
  
  # Check for pending migrations file
  pending_path = joinpath(settings.db_def_folder, "migrations", "pending_migrations.jl")
  has_pending = isfile(pending_path)
  
  if has_pending && !isempty(applied)
    push!(drift_signals, "Pending migrations file exists alongside applied history — review before applying.")
  end
  
  # Drift detection: check for failed migrations that need attention
  if !isempty(failed)
    push!(drift_signals, "$(length(failed)) failed migration(s) detected. Investigate and use mark_applied/mark_failed/remove_migration_record to reconcile.")
  end
  
  # Basic drift detection: try to detect tables in the live schema that have no
  # migration history (possible out-of-band schema changes)
  if has_table && !isempty(applied)
    try
      live_tables = _get_live_table_names(connection)
      # Filter out internal tables
      internal_tables = Set(["pormg_migrations", "pormg_migrations_data", "sqlite_sequence"])
      live_user_tables = filter(t -> !(t in internal_tables), live_tables)
      
      if isempty(live_user_tables) && !isempty(applied)
        push!(drift_signals, "No user tables found in database but migrations are recorded — possible external drop.")
      end
    catch e
      # Don't fail status() if drift detection fails
      @debug "Drift detection skipped" exception=e
    end
  end
  
  # #740: the run_once steps, from their own table — empty until the first one runs.
  return MigrationStatus(applied, failed, superseded, has_pending, has_table, drift_signals,
                         _data_steps(connection))
end

function status(settings::PormGSettings)::MigrationStatus
  status(settings.connections, settings)
end

function status(db::String; config::Dict{String,PormGSettings} = config)::MigrationStatus
  settings = config[db]
  status(settings)
end

# ==============================================================================
# Migration Plan Loading & Ordering
# ==============================================================================

"""
    _load_migration_plan(settings) -> Vector{OrderedDict}

Load and return all OrderedDicts from the pending_migrations.jl file. The file is parsed, never
executed (`_read_migration_plan`, #710).
"""
_pending_plan_path(settings::PormGSettings)::String =
  joinpath(settings.db_def_folder, "migrations", "pending_migrations.jl")

function _load_migration_plan(settings::PormGSettings)::Vector{OrderedDict{String, String}}
  pending_path = _pending_plan_path(settings)
  if !isfile(pending_path)
    throw(InvalidMigrationError("No pending migrations found at: $pending_path"))
  end
  return _read_migration_plan(pending_path)
end

"""
    _order_statements(migration_plan) -> (ordered_statements, all_sql_content)

Order SQL statements for safe execution:

0. Data steps labelled `Data (pre): …` (#740)
1. New tables (CREATE TABLE)
2. Drop tables
3. Rename tables (#615)
4. Rename fields
5. All other alterations
6. Field CREATE INDEX (#152)
7. Data steps labelled `Data (post): …` (#740)

Returns the ordered statements and the concatenated SQL content for checksum. Statement order is
part of the checksum input, so changing a bucket changes the digest of every plan that uses it.

# Data steps (#740)

A hand-written entry whose label starts `Data (pre):` runs before every schema statement, and one
starting `Data (post):` after every one — so a backfill sees the column its plan adds, and the
indexes too. The label decides the position, not the binding's name: an entry anywhere else in the
catch-all bucket is ordered by the name of the binding it sits in, which is how a backfill could run
before its own `ADD COLUMN`. A plan with no such label orders exactly as it did before #740, and so
checksums the same. A label that starts `Data (` but is neither prefix is refused
(`_data_step_kind`).

# Why these buckets are safe without a dependency sort (#89)

There is **no topological ordering by foreign key** here, and none is needed, because PormG keeps
FK constraints out of the ordering problem entirely. Three properties carry that, and a regression
test pins each (`test/unit/test_migration_fk_ordering.jl`):

- **PostgreSQL never inlines an FK in `CREATE TABLE`.** `Dialect.create_table(::PormGPostgres, …)`
  emits columns only; every constraint arrives as a separate `ALTER TABLE … ADD CONSTRAINT`, which
  lands in bucket 5 — after every `CREATE TABLE`. Two new tables referencing each other therefore
  apply in any order, which a topological sort could not do at all: that is a *cycle*.
- **PostgreSQL drops with `CASCADE`**, so a parent can be dropped before its children are cleaned
  up.
- **SQLite runs the whole migration with `PRAGMA foreign_keys = OFF`** (`_execute_migration_lifecycle`,
  asserted via `_assert_foreign_keys_suspended`, #276), so its inline `REFERENCES` clauses constrain
  nothing during the migration.

Note the layer this function sits at: it receives the plan *after* `_read_migration_plan` has read it back
from `pending_migrations.jl`, and that reader keeps only the `OrderedDict` values — **the table name
is already gone**. A real dependency sort is therefore not expressible here at all; it would need
the file format to carry the dependency, which is frozen at v1
(`docs/src/migrations/stability.md`). If the invariant above is ever deliberately broken, the guard
test fails and that is the moment to design a format v2 — not to sort opaque SQL strings.

# `"Rename table"` runs before every column statement (#615)

A renamed table's step gets its own bucket, after `DROP TABLE` and ahead of everything that names a
column, and `get_migration_plan` renders ALL of that table's column work against the NEW name (while
asking the live catalog by the old one, which is what it still holds at plan time). The opposite
answer — keep the column work on the old name and rename last — was the one the pre-#615 producer
half-attempted, and it cannot be made coherent:

- **The declared model renders the new name whatever the caller passes.** The SQLite rebuild,
  PostgreSQL's model-based `alter_field`, `_add_constrains` and `_add_new_field`'s rebuild all name
  the table through `model_table_name(declared)`, so a rename-last plan would mix both names.
- **A child that also changes its key re-points to the new name.** A child whose foreign key targets
  the renamed model and ALSO changes it (a different `on_delete`, say) diffs as a `:repoint`
  (`REFERENCES "<new>"`), which lands in bucket 5 and can only execute once the rename has run. On
  SQLite the child's rebuild also runs `PRAGMA foreign_key_check`, which reports a violation for a
  parent table that does not exist yet — so rename-last aborts there.
- **Buckets 4 and 6 straddle the "everything else" bucket.** A rename in bucket 5 would sit between
  a `RENAME COLUMN` and a `CREATE INDEX` for the same table, so one of them would always target a
  name that no longer (or not yet) exists.

A child whose key changes in nothing but its target's name plans no statement at all (#678).
PostgreSQL's rename follows the table's OID and SQLite ≥ 3.26 rewrites the child's `REFERENCES`
clause itself, so `get_migration_plan` retargets the live references to the new name before it diffs
anything. Until then every such child re-pointed redundantly, and the re-point's `DROP CONSTRAINT`
(or SQLite child rebuild) made a pure rename destructive.
"""
function _order_statements(migration_plan)
  ordered = String[last(entry) for entry in _ordered_entries(migration_plan)]
  all_sql = join(ordered, "\n")
  return ordered, all_sql
end

# The reserved labels of a hand-written data step (#740). Matched by exact prefix, colon included —
# see `_data_step_kind`.
const DATA_PRE_PREFIX = "Data (pre):"
const DATA_POST_PREFIX = "Data (post):"
# What counts as an ATTEMPT at one: looser than the prefixes, in case and spacing, so `data (post):`
# or `Data(pre):` is refused as a misspelt data step instead of running in the catch-all bucket —
# detect loosely, parse strictly, as the plan-header lines are read.
const DATA_STEP_LOOSE_RE = r"^\s*data\s*\("i

"""
    _data_step_kind(label) -> Union{Symbol, Nothing}

`:pre` or `:post` for a data-step label (#740), `nothing` for any other label. A label that reads
like one — `data (`, in any case and spacing — but is neither reserved prefix exactly (`Data (Pre):`,
`Data(post):`, `Data (post)` without its colon, `Data (middle):`) raises `InvalidMigrationError`
naming it. Read as an ordinary label, a typo would
land in the catch-all bucket, ordered by the binding's name: the very ordering these prefixes exist
to replace, and silently.
"""
function _data_step_kind(label::AbstractString)::Union{Symbol, Nothing}
  startswith(label, DATA_PRE_PREFIX) && return :pre
  startswith(label, DATA_POST_PREFIX) && return :post
  occursin(DATA_STEP_LOOSE_RE, label) && throw(InvalidMigrationError(
    "Migration plan label $(repr(label)) reads like a data step but is not one: a data step's " *
    "label starts with exactly `$(DATA_PRE_PREFIX)` (runs before every schema statement) or " *
    "`$(DATA_POST_PREFIX)` (runs after every one), spelt exactly so. Fix the label, or rename it so it does not start with `Data (`."))
  return nothing
end

"""
    _ordered_entries(migration_plan) -> Vector{Pair{String, String}}

The plan's `label => sql` entries in execution order — the buckets `_order_statements` documents,
with each entry's label kept beside its SQL so `dry_run` can name the data steps (#740).
"""
function _ordered_entries(migration_plan)::Vector{Pair{String, String}}
  data_pre = Pair{String, String}[]        # #740: hand-written data steps, before every schema statement
  first_execution = Pair{String, String}[]
  second_execution = Pair{String, String}[]
  rename_table_execution = Pair{String, String}[]   # #615: before anything that names a column
  third_execution = Pair{String, String}[]
  last_execution = Pair{String, String}[]
  index_execution = Pair{String, String}[]   # #152: field CREATE INDEX runs AFTER same-table rebuilds
  data_post = Pair{String, String}[]       # #740: after every schema statement, indexes included

  for dict_instructs in migration_plan
    for (key, value) in dict_instructs
      entry = String(key) => String(value)
      # #740: first, ahead of the schema buckets. The label decides, never the binding it sits in —
      # and a data step named "Data (pre): Rename field …" must not fall into the `contains` arm.
      kind = _data_step_kind(key)
      if kind === :pre
        push!(data_pre, entry)
      elseif kind === :post
        push!(data_post, entry)
      elseif key == "New model"
        push!(first_execution, entry)
      elseif key == "Drop table"
        push!(second_execution, entry)
      elseif key == "Rename table"
        push!(rename_table_execution, entry)
      elseif contains(key, "Rename field")
        push!(third_execution, entry)
      elseif startswith(key, "Create index")
        # #152: a newly-added db_index field's CREATE INDEX must run AFTER any same-table rebuild. An
        # SQLite "Alter table:" rebuild DROP TABLEs the table (dropping every secondary index) and only
        # re-creates indexes snapshotted from the LIVE schema at planning time — which excludes an index
        # queued in the SAME migration, so a fresh index would be dropped and never re-created. Deferring
        # every field CREATE INDEX to the end lands it on the rebuilt table. Safe: a CREATE INDEX only
        # needs its table to exist. Matches "Create index on <field>" and, since #347, the model-level
        # "Create index: <name>" composite step — both for the same reason. "Remove index …" (different
        # prefix), "Create unique constraint: …" and the m2m "Create many-to-many unique index"
        # (separate join table) are excluded.
        push!(index_execution, entry)
      else
        push!(last_execution, entry)
      end
    end
  end

  return vcat(data_pre, first_execution, second_execution, rename_table_execution, third_execution,
              last_execution, index_execution, data_post)
end

# ==============================================================================
# Dry Run
# ==============================================================================

"""
    DryRunResult

Result of a dry-run migration analysis.

Contains only the substantive fields needed to evaluate the migration plan.
Use `is_destructive(r)` and `total_statements(r)` for derived properties.

- `checksum`, `statements` — the plan's SQL in execution order, and its digest.
- `destructive_statements` — the statements the destructive guard flags (a `DROP`, a `TRUNCATE`, a
  `DELETE` with no `WHERE`).
- `lossy_alters` — the plan's lossy column changes (#803), one [`LossyAlter`](@ref) each, with `rows`
  counted against the live database for those that fail on existing rows.
- `data_steps` — the labels of the plan's hand-written data steps (#740), in the order they run:
  every `Data (pre): …` before the schema statements, every `Data (post): …` after them.
"""
struct DryRunResult
  checksum::String
  statements::Vector{String}
  destructive_statements::Vector{String}
  lossy_alters::Vector{LossyAlter}
  data_steps::Vector{String}
end

"""
    is_destructive(r::DryRunResult) -> Bool

Whether applying the plan needs `migrate(…; destructive = true)`: it has a destructive statement, or
a column change that silently alters existing values (a lower `NUMERIC` scale, say — #803). A plan
that would fail on existing rows is not "destructive"; `migrate` refuses it whatever the opt-in —
see `r.lossy_alters`.
"""
is_destructive(r::DryRunResult) = !isempty(r.destructive_statements) || !isempty(_silent_alters(r.lossy_alters))

"""Total number of SQL statements in the dry-run result."""
total_statements(r::DryRunResult) = length(r.statements)

function Base.show(io::IO, r::DryRunResult)
  println(io, "Dry Run Result:")
  println(io, "  Checksum: ", first(r.checksum, 16), "...")
  println(io, "  Total statements: ", total_statements(r))
  if !isempty(r.destructive_statements)
    println(io, _emsg(io, "  \e[31m⚠ DESTRUCTIVE: $(length(r.destructive_statements)) destructive statement(s)\e[0m"))
    for s in r.destructive_statements
      # Show first 120 chars of each destructive statement. `first`, not `s[1:120]`: a byte index
      # can land inside a multibyte character of a table name or a default.
      display_s = length(s) > 120 ? first(s, 120) * "..." : s
      println(io, "    → ", display_s)
    end
  end
  # #803, one section per class — each asks something different of the operator.
  silent = _silent_alters(r.lossy_alters)
  failing = _failing_alters(r.lossy_alters)
  if !isempty(silent)
    println(io, _emsg(io, "  \e[31m⚠ CHANGES EXISTING VALUES: $(length(silent)) column change(s) — needs `destructive = true`\e[0m"))
    for f in silent
      println(io, "    → ", _lossy_alter_summary(f))
    end
  end
  if !isempty(failing)
    println(io, _emsg(io, "  \e[31m✗ WOULD FAIL: $(length(failing)) column change(s) — migrate() refuses this plan\e[0m"))
    for f in failing
      println(io, "    → ", _lossy_alter_summary(f))
    end
  end
  if isempty(r.destructive_statements) && isempty(silent) && isempty(failing)
    println(io, _emsg(io, "  \e[32m✓ Safe (no destructive operations)\e[0m"))
  end
  # #740: hand-written data steps, named — the SQL list below does not say which statements are data.
  if !isempty(r.data_steps)
    println(io, "  Data steps: ", length(r.data_steps), " (hand-written; `pre` runs before the schema statements, `post` after)")
    for label in r.data_steps
      println(io, "    → ", label)
    end
  end
  println(io, "\n  SQL statements:")
  for (i, s) in enumerate(r.statements)
    display_s = length(s) > 200 ? first(s, 200) * "..." : s
    println(io, "    $i. ", display_s)
  end
end

"""
    dry_run(connection, settings) -> DryRunResult

Analyze pending migrations without applying them.
Validates ordering, checksums, destructive actions, and SQL generation.
Does NOT modify the database or move files.

When the plan's header records a lossy column change (#803), `dry_run` reads the database: it
checks each such column still exists and, for a change that can fail on existing rows, counts those
rows with a read-only `SELECT COUNT(*)`, reported in `r.lossy_alters`. A plan with no such change
reads nothing.
"""
function dry_run(connection::Union{PormGPostgres, PormGSQLite}, settings::PormGSettings)::DryRunResult
  Configuration._require_folder_backed(settings, "dry_run")
  migration_plan = _load_migration_plan(settings)
  # The same ordering `_order_statements` returns, with each label kept, so the data steps can be
  # named (#740).
  entries = _ordered_entries(migration_plan)
  ordered_statements = String[last(e) for e in entries]
  all_sql = join(ordered_statements, "\n")
  
  checksum = compute_checksum(all_sql)
  destructive_stmts = detect_destructive_actions(ordered_statements)
  lossy_alters = _anchor_check_conditions(_plan_lossy_alters(_pending_plan_path(settings)), settings)
  isempty(lossy_alters) || (lossy_alters = _precheck_lossy_alters(connection, lossy_alters))

  return DryRunResult(
    checksum,
    ordered_statements,
    destructive_stmts,
    lossy_alters,
    String[first(e) for e in entries if _data_step_kind(first(e)) !== nothing]
  )
end

function dry_run(settings::PormGSettings)::DryRunResult
  dry_run(settings.connections, settings)
end

function dry_run(db::String; config::Dict{String,PormGSettings} = config)::DryRunResult
  settings = config[db]
  dry_run(settings)
end

# ==============================================================================
# migrate() outcome (#737)
# ==============================================================================

const _MIGRATION_OUTCOMES = (:applied, :already_applied, :nothing_pending, :disabled, :declined)

"""
    MigrationResult

What one [`migrate`](@ref) call did. Every path through `migrate` that does not throw returns one,
so a script that runs `migrate` at boot can branch on the outcome instead of parsing the log.

  * `outcome` — one of:

    | `outcome` | Meaning |
    | :--- | :--- |
    | `:applied` | The pending plan ran in one transaction and is recorded in `pormg_migrations`. |
    | `:already_applied` | The pending plan is the latest applied migration (its checksum matches): another instance applied it first, or a previous `migrate` committed it and then failed to archive the file. Nothing ran; the file is archived — by this call, or already by an instance sharing the plan folder (#81). |
    | `:nothing_pending` | There is no `pending_migrations.jl`, or it holds no statements. The history table and any configured extensions were still ensured. |
    | `:disabled` | The connection is `change_db: false`. Nothing was read or written. |
    | `:declined` | An interactive run was not confirmed at the prompt, a destructive plan was refused there for lack of `destructive = true`, or a column change would fail on existing rows (#803). |

  * `version` — the `pormg_migrations.version` of the row involved: the new row for `:applied`,
    the matched row for `:already_applied`, `nothing` for every other outcome.
  * `n_statements` — how many plan statements this call executed: the plan's size for `:applied`,
    `0` for every other outcome.

A **failure** is still an exception, not an outcome: a destructive plan without
`destructive = true` in a non-interactive run (`DestructiveMigrationError`), a column change that
would fail on existing rows (`MigrationPrecheckError`, raised before anything is written), a
database that no longer holds the schema the plan was generated against (`PlanPreconditionError`,
raised before anything is written, #739), a plan file that does not parse (`InvalidMigrationError`), a statement the database rejects (the plan is rolled back,
recorded as `failed`, and the error rethrown), and a migration lock not acquired within `lock_wait`
(`OperationalError`).

```julia
result = PormG.Migrations.migrate("db"; interactive = false)
if result.outcome === :applied
    @info "Schema migrated" result.version result.n_statements
end
```

See the [Deploying](@ref deploying-migrations) guide for running `migrate` at application boot.
"""
struct MigrationResult
  outcome::Symbol
  version::Union{String, Nothing}
  n_statements::Int

  function MigrationResult(outcome::Symbol, version::Union{AbstractString, Nothing}, n_statements::Integer)
    outcome in _MIGRATION_OUTCOMES || throw(InvalidValueError(
      "Unknown migrate() outcome $(repr(outcome)). Expected one of: $(join(repr.(_MIGRATION_OUTCOMES), ", "))."))
    n_statements >= 0 || throw(InvalidValueError(
      "MigrationResult n_statements must not be negative, got $(n_statements)."))
    return new(outcome, version === nothing ? nothing : String(version), Int(n_statements))
  end
end

function Base.show(io::IO, ::MIME"text/plain", r::MigrationResult)
  println(io, "Migration Result: ", r.outcome)
  r.version === nothing || println(io, "  Version: ", r.version)
  print(io, "  Statements executed: ", r.n_statements)
end

# The three wait bounds a `migrate` call takes (#737), validated once, in milliseconds.
#
#   lock_wait_ms          how long to wait for the migration advisory lock (PostgreSQL)
#   lock_timeout_ms       `SET LOCAL lock_timeout` in the migration transaction, or `nothing`
#   statement_timeout_ms  `SET LOCAL statement_timeout` in the migration transaction, or `nothing`
struct _MigrationTimeouts
  lock_wait_ms::Int
  lock_timeout_ms::Union{Int, Nothing}
  statement_timeout_ms::Union{Int, Nothing}
end

# PostgreSQL's `lock_timeout` and `statement_timeout` are `int` milliseconds, so this is the largest
# value either accepts. The client-side lock wait is held to it too, so the three read alike.
const _MAX_MIGRATION_TIMEOUT_MS = Int(typemax(Int32))

# Seconds in, milliseconds out. The value reaches SQL only as this `Int`, formatted by Julia, so no
# caller text is ever interpolated into the `SET LOCAL` statements.
_migration_timeout_ms(::String, ::Nothing) = nothing
function _migration_timeout_ms(name::String, seconds::Real)::Int
  ms = seconds * 1000
  (seconds isa Bool || !isfinite(ms) || ms <= 0 || ms > _MAX_MIGRATION_TIMEOUT_MS) &&
    throw(InvalidValueError(
      "migrate(...; $(name) = $(repr(seconds))): expected a positive number of seconds, at most " *
      "$(_MAX_MIGRATION_TIMEOUT_MS ÷ 1000) (PostgreSQL's limit for a timeout)."))
  return max(1, round(Int, ms))
end

_migration_timeouts(lock_wait::Real = 30, lock_timeout = nothing, statement_timeout = nothing) =
  _MigrationTimeouts(_migration_timeout_ms("lock_wait", lock_wait),
                     _migration_timeout_ms("lock_timeout", lock_timeout),
                     _migration_timeout_ms("statement_timeout", statement_timeout))

# ==============================================================================
# Schema Check API (#475)
# ==============================================================================

"""
    SchemaCheckFinding

One fact about the live database, as reported by [`check`](@ref).

  * `kind` — the finding class: `:expression_default`, `:schema_drift` or `:invalid_index`.
  * `table` — the table name.
  * `columns` — the column name(s) the finding is about. One entry for a column finding, none for a
    table-level one (a `:schema_drift` "New model" or "Drop table", and every `:invalid_index`).
  * `detail` — the text the finding is about, verbatim: for `:expression_default`, the `DEFAULT`
    expression as the database renders it; for `:schema_drift`, the label of the step
    `makemigrations` would plan (`"Add field: country"`, `"Drop table"`, …); for `:invalid_index`,
    the index name.
  * `message` — a one-line explanation of the consequence (for `:invalid_index`, also the remedy
    and the index definition).
"""
struct SchemaCheckFinding
  kind::Symbol
  table::String
  columns::Vector{String}
  detail::String
  message::String
end

"""
    SchemaCheckResult

Structured result from [`check`](@ref): the backend that was read (`:postgres` or `:sqlite`) and
the [`SchemaCheckFinding`](@ref)s, ordered by kind, then table, then column so two runs against the
same schema render identically.

`isempty(result)` is true when the requested finding classes found nothing — for
`kinds = [:schema_drift]`, when the database matches the declared models. That is the CI gate:

```julia
r = PormG.Migrations.check("db"; kinds = [:schema_drift])
exit(isempty(r) ? 0 : 1)
```
"""
struct SchemaCheckResult
  backend::Symbol
  findings::Vector{SchemaCheckFinding}
end

Base.isempty(r::SchemaCheckResult) = isempty(r.findings)

# Re-scoped by #496, deliberately, and the issue's acceptance list asks for the choice to be named.
# The class detects exactly the same columns as before — `_expression_default_finding` is unchanged
# — but what it MEANS changed completely. Before #496 it reported a column PormG could not express,
# and the advice was "declare nothing here". Since #496 the column imports faithfully as a
# `db_default`, so there is nothing unrepresentable left to report; what remains worth reporting is
# PORTABILITY, because a non-vocabulary expression is pinned to the engine it was read from and the
# generated models file will refuse to render it on the other one.
#
# Kept as `:expression_default` rather than renamed: the symbol is a semi-public field on
# `SchemaCheckFinding`, the detected set is identical, and a rename would churn every call site and
# test for no information gained. The docstring below and `docs/src/schema_conventions.md` say which
# reading is current.
const _EXPRESSION_DEFAULT_MESSAGE =
  "the DEFAULT is a SQL expression; it imports as `db_default=` with exactly this text. Declare it " *
  "that way and NOT as `default=`, which would render it as a quoted literal"

function Base.show(io::IO, r::SchemaCheckResult)
  println(io, "Schema Check (", r.backend, "):")
  if isempty(r.findings)
    println(io, _emsg(io, "  \e[32m✓ no findings\e[0m"))
    return
  end
  println(io, "  ", length(r.findings), " finding(s)")
  for kind in unique(f.kind for f in r.findings)
    group = filter(f -> f.kind === kind, r.findings)
    println(io, _emsg(io, "\n  \e[33m$(kind)\e[0m ($(length(group)))"))
    for f in group
      where = isempty(f.columns) ? f.table : string(f.table, ".", join(f.columns, ","))
      if kind === :expression_default
        println(io, "    ⚠ ", where, "  DEFAULT ", f.detail)
      else
        # A drift finding's message differs per step (which side has it, a possible rename), so it
        # goes on the finding's own line rather than once under the group.
        println(io, "    ⚠ ", where, "  ", f.detail, " — ", f.message)
      end
    end
    # Every `:expression_default` finding carries the same advice; print it once.
    kind === :expression_default && println(io, "      ", first(group).message)
  end
end

# The `:expression_default` findings — the columns whose DEFAULT is a SQL expression rather than a
# literal (#475), which since #496 the readers CARRY as a `db_default` instead of dropping.
#
# Decided with the READERS' OWN pure helpers rather than a mirror of them (#522): `_clean_default` is
# the classification `_default_or_drop` applies, `_key_arm` the arm selection both readers use, and
# `is_valid_db_default_sql` the well-formedness rule the reader drops on — so `check` cannot disagree
# with `makemigrations` about which columns are affected. This replaced two per-engine copies of the
# readers' arm order (`_pg_key_arm_ignores_default`, `_sqlite_key_arm_ignores_default`) whose own
# comment said they could drift, and the agreement assertions in `test/unit/test_migrations_check.jl`
# and `test/integration/test_importers_introspection.jl` (section 6b) are what would have caught it.
#
# THE SKIP IS EVERY ARM THAT COMPILES TO AN `sIDField`, not just an integer key, and #496 widened it
# because the ADVICE changed. `_integer_key_arm` was the right skip while the message said "declare
# no `default=` here" — true of every key arm, so only the noisiest one needed suppressing. The
# message now says "declare it as `db_default=`", which is true only where the field HAS that slot,
# and `sIDField` has none: PostgreSQL rejects a column that is both `GENERATED … AS IDENTITY` and
# carries a `DEFAULT`. A `BLOB PRIMARY KEY DEFAULT (randomblob(16))` was therefore reported and told
# to declare a keyword `IDField` warns about and ignores. `_arm_carries_db_default` is that rule,
# and `field_from_spec` gates on it too rather than re-deciding.
#
# (The older reason for suppressing the integer key stands underneath: it is NOT that `IDField`
# expresses a `serial` column's `nextval(…)` — a legacy `serial` key reads back `generated = false`
# and `makemigrations` proposes `ADD GENERATED BY DEFAULT AS IDENTITY` for it, upgrade-log #438.)
#
# Erring toward REPORTING is still deliberate everywhere else: `check` being silent about a column
# whose default the user needs to know about is the dangerous direction, and being noisy is merely
# annoying. What is NOT acceptable is reporting one with advice that cannot be followed.
function _expression_default_finding(table_name, col_name, raw_default, ctype, is_pk::Bool,
                                     has_reference::Bool, conn)::Union{SchemaCheckFinding, Nothing}
  (raw_default === nothing || ismissing(raw_default)) && return nothing
  # #496 widened this skip from `_integer_key_arm` to every arm that compiles to an `sIDField`,
  # because the ADVICE changed. The old message said "declare no `default=` here", which is true of
  # any key arm; the new one says "declare it as `db_default=`", which is only true where the field
  # has that slot. A `BLOB PRIMARY KEY DEFAULT (randomblob(16))` lands on `:id_pk`, imports as
  # `IDField` with the expression discarded, and would have been told to declare a keyword `IDField`
  # warns about and ignores. One predicate, shared with the importer, so the two cannot drift.
  _arm_carries_db_default(_key_arm(is_pk, ctype, has_reference), ctype, conn) || return nothing
  cleaned = _clean_default(raw_default, ctype, conn)
  cleaned isa _ExpressionDefault || return nothing
  # …and the SAME well-formedness predicate the reader applies. Without it this is H1's shape one
  # layer over: the reader would DROP such a value while `check` still said "declare it as
  # `db_default=` with exactly this text", and pasting it would raise `FieldValidationError` from
  # the constructor — advice that does not merely fail to work but errors when followed. The two
  # policies differ deliberately (reader drops, constructor throws), which is exactly why `check`
  # has to ask the question rather than assume the answer. Found in the delta review.
  is_valid_db_default_sql(cleaned.sql) || return nothing
  return SchemaCheckFinding(:expression_default, String(table_name), [String(col_name)], cleaned.sql,
                            _EXPRESSION_DEFAULT_MESSAGE)
end

# The PostgreSQL arm. Pure over the frame `get_database_schema(::PormGPostgres)` returns, so it is
# unit-testable against a synthetic `DataFrame` with no live database — the same trick the reader's
# own tests play with `_introspection_row`.
function _pg_expression_default_findings(schemas::AbstractDataFrame;
                                         ignore_table::Vector{String})::Vector{SchemaCheckFinding}
  findings = SchemaCheckFinding[]
  engine = _PostgresEngine()
  for row in eachrow(schemas)
    _is_ignored_table(row.table_name, ignore_table) && continue
    pk_set = Set{String}(String.(something(_pg_json(row, :primary_keys), Any[])))
    # The `foreign_keys` CTE already keeps single-column keys only, the way the reader does.
    fk_cols = Set{String}(String(fk["column"]) for fk in
                          something(_pg_json(row, :foreign_keys), Any[]))
    for col in something(_pg_json(row, :columns), Any[])
      col_name = String(col["name"])
      ctype = parse_canonical_type(String(get(col, "type", "")), engine)
      finding = _expression_default_finding(row.table_name, col_name, get(col, "default", nothing),
                                            ctype, col_name in pk_set, col_name in fk_cols, engine)
      finding === nothing || push!(findings, finding)
    end
  end
  return findings
end

# The SQLite arm. `PRAGMA table_info`, the source the live reader uses — which is the point: `check`
# must not be able to disagree with `makemigrations` about which columns are affected.
function _sqlite_expression_default_findings(db::PormGSQLite;
                                             ignore_table::Vector{String},
                                             include_table::Union{Vector{String}, Nothing} = nothing)::Vector{SchemaCheckFinding}
  findings = SchemaCheckFinding[]
  # The reader's own table list (#730), so a virtual or shadow table is no more reported here than
  # it is read by `makemigrations`.
  for table_name in _sqlite_user_table_names(db)
    if include_table !== nothing
      !any(included -> table_name == included, include_table) && continue
    end
    _is_ignored_table(table_name, ignore_table) && continue

    # The same bound pragma functions the live reader uses (#832).
    cols = fetch(db, "SELECT * FROM pragma_table_info(?)", [table_name]) |> DataFrame
    # The reader SKIPS a composite foreign key rather than splitting it into N single-column
    # relations (#415), so such a child column has no relation and falls through to the
    # bare-`IDField` key arm when it is a key. `fk_cols` has to be filtered the same way or the arm
    # below would differ from the reader's. PostgreSQL needs no equivalent: its `foreign_keys` CTE
    # already filters on `array_length(con.conkey, 1) = 1`.
    fks = fetch(db, "SELECT * FROM pragma_foreign_key_list(?)", [table_name]) |> DataFrame
    cols_per_fk = Dict{Any, Int}()
    for r in eachrow(fks)
      cols_per_fk[r.id] = get(cols_per_fk, r.id, 0) + 1
    end
    fk_cols = Set{String}(String(r.from) for r in eachrow(fks) if cols_per_fk[r.id] == 1)
    for crow in eachrow(cols)
      col_name = String(crow.name)
      # The reader's own derivation of the type, through the reader's own helper.
      ctype = parse_canonical_type(_sqlite_declared_type(crow.type), db)
      finding = _expression_default_finding(table_name, col_name, crow.dflt_value, ctype,
                                            crow.pk isa Number && crow.pk > 0, col_name in fk_cols, db)
      finding === nothing || push!(findings, finding)
    end
  end
  return findings
end

# ---------------------------------------------------------------------------------------------
# `:invalid_index` — an index PostgreSQL marked invalid (#871)
# ---------------------------------------------------------------------------------------------

# Every invalid index (`NOT pg_index.indisvalid`) on a table the readers read: the same `relkind`,
# ownable-table filter (#730) and schema as `_pg_table_checks`. Both index readers SKIP such an
# index (#847) — never read, never dropped — and that contract stays; this is the report that makes
# the skip visible, so nobody keeps one by accident.
#
# Deliberately NO shape filter. The readers keep b-tree, non-partial, non-expression indexes only,
# because those are the ones PormG can re-emit; an invalid GIN, partial or unique index is just as
# useless, and just as costly on writes, so it is reported too. Ordered by table, then index name:
# `_sort_findings` is stable and ties on `(kind, table)` here, so this ORDER BY is the final order.
function _pg_invalid_indexes(db::PormGPostgres; schema::Union{String, Nothing} = "public")::DataFrame
  schema_clause = schema === nothing ? "" : "AND n.nspname = \$1"
  params = schema === nothing ? String[] : String[schema]
  query = """
    SELECT c.relname AS table_name,
           ic.relname AS index_name,
           n.nspname AS schema_name,
           i.indisunique AS is_unique,
           i.indisready AS is_ready,
           pg_get_indexdef(i.indexrelid) AS def
    FROM pg_index i
    JOIN pg_class ic ON ic.oid = i.indexrelid
    JOIN pg_class c ON c.oid = i.indrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE NOT i.indisvalid
      AND c.relkind = 'r'
      $(_PG_OWNABLE_TABLE_FILTER)
      $(schema_clause)
    ORDER BY c.relname, ic.relname;
    """
  return DataFrame(fetch(db, query, params))
end

# The consequence and the remedy, with the name quoted and schema-qualified so the statement can be
# pasted as is. PostgreSQL's own wording for the state (CREATE INDEX, "Building Indexes
# Concurrently"): ignored for querying, still consuming update overhead. `indisready` sharpens that
# (found in review): a READY index is inserted into on every write, and a ready unique one keeps
# rejecting duplicates (the docs' caveat on unique concurrent builds); one that never became ready —
# the common case, a unique build failing on duplicates — is skipped on insert, so what it still
# costs is its disk space and the HOT updates it blocks, being in the table's index list.
#
# DROP leads, and REINDEX is offered only where it is a fix (found in review). A failed
# `REINDEX CONCURRENTLY` leaves a `<name>_ccnew` copy beside an intact original (or, failing after the
# swap, a `<name>_ccold`): reindexing THAT copy would make it a valid duplicate of the original —
# paid for on every write, and silent from then on, because it is no longer invalid. PostgreSQL's
# own advice for either is to drop it. For any other index the cause has to go first (a unique build
# that failed on duplicates fails the same way again), and `REINDEX … CONCURRENTLY` is 12+ while
# PormG's floor is 11, so it is the alternative, not the instruction.
const _REINDEX_LEFTOVER_RE = r"_cc(new|old)\d*$"

function _invalid_index_message(schema::AbstractString, index_name::AbstractString, unique::Bool,
                                ready::Bool, def::AbstractString)::String
  quoted = "\"$(Dialect._quote_table_ddl(schema))\".\"$(Dialect._quote_table_ddl(index_name))\""
  cost = ready ? "still maintains it on every write" * (unique ? " and still rejects duplicate values with it" : "") :
                 "it still takes disk space and keeps updates to its columns from being HOT"
  head = "invalid index: PostgreSQL never uses it for queries, but $(cost). " *
         "One still being built CONCURRENTLY reads the same until it finishes. "
  leftover = match(_REINDEX_LEFTOVER_RE, index_name)
  remedy = if leftover !== nothing && leftover.captures[1] == "new"
    "It looks like the new copy a failed REINDEX CONCURRENTLY left beside the original, which is " *
    "intact: drop this copy with `DROP INDEX CONCURRENTLY $(quoted);` and do not re-create or " *
    "reindex it (that makes a valid duplicate of the original), then retry the REINDEX if you still " *
    "want one."
  elseif leftover !== nothing
    "It looks like the old copy a REINDEX CONCURRENTLY swapped out before failing; the rebuilt index " *
    "is already in place: drop this copy with `DROP INDEX CONCURRENTLY $(quoted);` and do not " *
    "re-create it."
  else
    cause = unique ? " (for a unique index, usually duplicate values)" : ""
    "Usually a failed CREATE INDEX CONCURRENTLY. Drop it with `DROP INDEX CONCURRENTLY $(quoted);`, " *
    "remove what made the build fail$(cause), and create it again from the definition below; on " *
    "PostgreSQL 12 or later, `REINDEX INDEX CONCURRENTLY $(quoted);` rebuilds it in place instead, " *
    "once the cause is gone."
  end
  return head * remedy * " Definition: $(def)"
end

function _pg_invalid_index_findings(db::PormGPostgres; ignore_table::Vector{String},
                                    include_table::Union{Vector{String}, Nothing} = nothing)::Vector{SchemaCheckFinding}
  findings = SchemaCheckFinding[]
  rows = _pg_invalid_indexes(db)
  nrow(rows) == 0 && return findings
  for r in eachrow(rows)
    (r.table_name === missing || r.index_name === missing) && continue
    table_name = String(r.table_name)
    include_table === nothing || table_name in include_table || continue
    _is_ignored_table(table_name, ignore_table) && continue
    # `columns` stays empty: an index is a table-level object, like a `"New model"` drift finding.
    push!(findings, SchemaCheckFinding(:invalid_index, table_name, String[], String(r.index_name),
      _invalid_index_message(coalesce(r.schema_name, "public"), r.index_name,
                             coalesce(r.is_unique, false) === true, coalesce(r.is_ready, false) === true,
                             coalesce(r.def, ""))))
  end
  return findings
end

# ---------------------------------------------------------------------------------------------
# `:schema_drift` — the declared models against the live schema (#738)
# ---------------------------------------------------------------------------------------------

# The finding classes `check(...; kinds)` accepts.
const _CHECK_KINDS = (:expression_default, :schema_drift, :invalid_index)

function _validate_check_kinds(kinds::AbstractVector{Symbol}, models_file)
  isempty(kinds) && throw(InvalidValueError(
    "check(...; kinds = []) would report nothing whatever the database holds, so a gate built on " *
    "it could never fail. Name at least one of: $(join(repr.(_CHECK_KINDS), ", "))."))
  for kind in kinds
    kind in _CHECK_KINDS || throw(InvalidValueError(
      "Unknown check() finding class $(repr(kind)). Expected one of: $(join(repr.(_CHECK_KINDS), ", "))."))
  end
  # Refused rather than ignored: a caller who passed a models file expects it to be read.
  models_file === nothing || :schema_drift in kinds || throw(InvalidValueError(
    "check(...; models_file = …) is read only by the :schema_drift class. Pass " *
    "kinds = [:schema_drift], or drop models_file."))
  return nothing
end

# The declared side: the models file loaded into a throwaway module — `makemigrations`' own loader,
# so the two cannot disagree about what the models declare, and nothing global is touched
# (`_load_current_models` never runs `set_models`). A path rather than an already-loaded module on
# purpose: the planner writes resolved foreign-key targets back into the field objects it is given,
# and those would be a running application's live models.
function _drift_declared_models(settings::PormGSettings, models_file)
  return _load_current_models(_resolve_models_file(settings, models_file, "check(kinds = [:schema_drift])"))
end

# The models file a planning entry point diffs against, as an ABSOLUTE path — shared by
# `makemigrations(db; models_file)` and `check(kinds = [:schema_drift])` (#736), so the two cannot
# disagree about which file a `models_file` names. `nothing` is the connection's own
# `<db_def_folder>/<model_file>`; anything else is taken as given, a relative path against the
# working directory. Absolute because `Base.include` resolves a relative path against the file being
# included, not the working directory — the String form of `makemigrations` handed it
# `joinpath(db, …)` as is, while its own `isfile` check had resolved that against the cwd.
function _resolve_models_file(settings::PormGSettings, models_file, action::String)::String
  if models_file === nothing
    # The folder is where the default models file lives (#683).
    Configuration._require_folder_backed(settings, action)
    path = joinpath(settings.db_def_folder, settings.model_file)
    isfile(path) || throw(MissingConfigurationError(
      "$(action) compares the database against the connection's models file, and $(path) does not " *
      "exist. Create it, or pass `models_file = \"…\"` to name another."))
  else
    path = String(models_file)
    isfile(path) || throw(MissingConfigurationError(
      "$(action) was given `models_file = \"$(path)\"`, which does not exist."))
  end
  return abspath(path)
end

# `"Add field: country"` → `"country"`; `nothing` for a label that names no single column.
function _drift_label_column(label::AbstractString)::Union{String, Nothing}
  m = match(r"^(?:Add|Remove|Rename|Alter) field: (.+)$", label)
  return m === nothing ? nothing : String(m.captures[1])
end

function _drift_message(label::AbstractString)::String
  (label == "New model" || startswith(label, "Add field: ")) &&
    return "declared in the models, missing from the database"
  (label == "Drop table" || startswith(label, "Remove field: ")) &&
    return "in the database, not declared in the models"
  return "the database and the models differ here; makemigrations would plan this step"
end

const _DRIFT_RENAME_NOTE = "(makemigrations asks; a non-interactive plan never renames, it drops and creates)"

# One finding per planned step. A plan built with `interactive = false` never renames, so a renamed
# column is an add plus a remove and a renamed table a new model plus a drop. Both halves are drift —
# the live and declared names differ — but each says what it might pair with, so the reader knows it
# may be one change rather than two (#738).
function _drift_findings(plan::OrderedDict{Symbol, OrderedDict{String, String}})::Vector{SchemaCheckFinding}
  new_tables = [String(t) for (t, steps) in plan if haskey(steps, "New model")]
  dropped_tables = [String(t) for (t, steps) in plan if haskey(steps, "Drop table")]
  findings = SchemaCheckFinding[]
  for (table, steps) in plan
    added = String[c for c in (_drift_label_column(l) for l in keys(steps) if startswith(l, "Add field: ")) if c !== nothing]
    removed = String[c for c in (_drift_label_column(l) for l in keys(steps) if startswith(l, "Remove field: ")) if c !== nothing]
    for label in keys(steps)
      message = _drift_message(label)
      pair = if label == "New model" && !isempty(dropped_tables)
        "of " * join(dropped_tables, " or ")
      elseif label == "Drop table" && !isempty(new_tables)
        "to " * join(new_tables, " or ")
      elseif startswith(label, "Add field: ") && !isempty(removed)
        "of " * join(removed, " or ")
      elseif startswith(label, "Remove field: ") && !isempty(added)
        "to " * join(added, " or ")
      else
        nothing
      end
      pair === nothing || (message *= "; it could be a rename $(pair) $(_DRIFT_RENAME_NOTE)")
      column = _drift_label_column(label)
      push!(findings, SchemaCheckFinding(:schema_drift, String(table),
                                         column === nothing ? String[] : [column], label, message))
    end
  end
  return findings
end

# The `:schema_drift` class: what the next `makemigrations` would plan, computed and not written.
#
# `makemigrations` itself could not serve as the gate, for three reasons it has good cause to keep:
# it writes `pending_migrations.jl`, it refuses to run under `change_db: false` (what a production
# connection usually carries), and it logs a failed live read and returns. Here the plan is built in
# memory with `interactive = false` — no prompt, no file — `change_db` is not consulted, and the live
# read has no `try` around it: a gate must never report clean because it could not look.
function _schema_drift_findings(connection::Union{PormGPostgres, PormGSQLite}, settings::PormGSettings;
                                ignore_table::Vector{String},
                                include_table::Union{Vector{String}, Nothing},
                                models_file)::Vector{SchemaCheckFinding}
  declared = _drift_declared_models(settings, models_file)
  live = read_live_schema(connection; ignore_table = ignore_table, include_table = include_table)
  plan = get_migration_plan(live, declared, connection, settings; interactive = false)
  # `include_table` is applied to the PLAN, not to the declared models. Narrowing the declared side
  # before planning looked equivalent and was not: the planner synthesizes each ManyToManyField's
  # through table from the declared models, so an included owner still produced a through table
  # the (narrowed) live side lacked — a false "New model" — and a string M2M target outside the list
  # could not be resolved at all. Planning with every declared model and reporting only the listed
  # tables keeps the plan identical to the one `makemigrations` would build for them. The declared
  # models outside the list plan as new tables (the live read skipped them) and are dropped here.
  include_table === nothing || filter!(p -> String(first(p)) in include_table, plan)
  return _drift_findings(plan)
end

_sort_findings(f::Vector{SchemaCheckFinding}) =
  sort(f; by = x -> (String(x.kind), x.table, isempty(x.columns) ? "" : first(x.columns)))

"""
    check(connection, settings; kinds = [:expression_default], ignore_table = nothing, include_table = nothing, models_file = nothing) -> SchemaCheckResult
    check(settings; kwargs...) -> SchemaCheckResult
    check(db::String; config = config, kwargs...) -> SchemaCheckResult

Report facts about the live database schema, one [`SchemaCheckFinding`](@ref) each. Read-only on
both backends: `check` never writes, never prompts, and does not consult `change_db`, so it runs
against a production connection.

`kinds` selects the finding classes:

  * `:expression_default` (the default) — columns whose `DEFAULT` PormG's models express only as a
    `db_default`. Needs no models file, no migration history and no `init_migrations()`.
  * `:schema_drift` — every place the database differs from the **declared models**: one finding
    per step the next [`makemigrations`](@ref) would plan. Empty means the database matches the
    models, which makes it a CI or release gate:

    ```julia
    r = PormG.Migrations.check("db"; kinds = [:schema_drift])
    exit(isempty(r) ? 0 : 1)
    ```
  * `:invalid_index` — every index PostgreSQL has marked invalid, typically left by a failed
    `CREATE INDEX CONCURRENTLY`. PostgreSQL-only in effect: SQLite has no such state, so there the
    class is accepted and always reports nothing.

`ignore_table` replaces the backend's default skip list (`postgres_ignore_table` /
`sqlite_ignore_schema`, less the connection's `unignore_defaults:` entries, #818); tables registered
through `register_ignore_tables!` and the connection's own `ignore_tables:` in `connection.yml` (#749)
are always skipped on top of it, so `check` reads exactly the tables the importer and `makemigrations`
do. `include_table`
restricts the read to the named tables. Both match the parameters of `convert_schema_to_models`.
For `:schema_drift` the two filter differently, on purpose:

  * `include_table` restricts what is **reported**. Every declared model is still planned, so the
    findings for a listed table are exactly the steps `makemigrations` would plan for it. A
    `ManyToManyField`'s through table is reported only when it is listed too.
  * `ignore_table` skips **live** tables only, as the default skip list does for `makemigrations`.
    A declared model on a table only this keyword names therefore reads as missing from the
    database. A managed model on a table under one of the lists `makemigrations` reads with, which
    are the backend default, `register_ignore_tables!` and the connection's `ignore_tables:`, raises
    `InvalidConfigurationError` instead, as it does in `makemigrations` (#749, #805). Replacing the
    default list with this keyword does not switch that refusal off; listing the default entry
    under `unignore_defaults:` does, for that connection (#818).

`models_file` names the models file
`:schema_drift` compares against; by default it is `settings.model_file` under the connection's
folder, the file `makemigrations` reads. An empty `kinds`, an unknown class, or a `models_file`
without `:schema_drift` raises `InvalidValueError`.

Run it alongside [`status`](@ref) and [`dry_run`](@ref) in the operator flow, and before upgrading
PormG.

# `:schema_drift`

Each finding is one planned step: `table` is the table, `columns` the column a field step names,
`detail` the step's label exactly as `makemigrations` writes it into a plan (`"New model"`,
`"Drop table"`, `"Add field: country"`, `"Remove field: code"`, `"Alter field: points"`, …), and
`message` which side has what the other lacks.

  * **It reads what `makemigrations` reads, and plans the same way** — the same live reader, the same
    models loader, the same planner, with `interactive = false`. So it cannot disagree with the next
    `makemigrations` about whether there is a change.
  * **A failed read raises.** Unlike `makemigrations`, which logs a failed live read and returns, a
    gate must never report "clean" because it could not look.
  * **An unhinted rename is drift.** With no one to ask, a renamed column plans as an add plus a
    remove, and a renamed table as a new model plus a drop. Both findings are reported, and each
    `message` names the other half it could pair with.
  * **A changed column reads differently per engine.** PostgreSQL alters a column in place and
    reports `"Alter field: <column>"`. SQLite rebuilds the table, so the finding is
    `"Alter table: <table>"` and names no column. Added and removed columns keep their
    `"Add field: …"` / `"Remove field: …"` labels on both engines.
  * **The declared models are loaded the way `makemigrations` loads them** — the file is included
    into a throwaway module and `set_models` never runs — so checking does not touch the models an
    application has already loaded.

```julia
julia> PormG.Migrations.check("db"; kinds = [:schema_drift])
Schema Check (postgres):
  2 finding(s)

  schema_drift (2)
    ⚠ circuit.country  Add field: country — declared in the models, missing from the database
    ⚠ season  New model — declared in the models, missing from the database
```

# `:expression_default`

A column whose `DEFAULT` is a SQL expression (`now()`, `CURRENT_TIMESTAMP`, `gen_random_uuid()`,
`concat(...)`) rather than a literal value. Since #496 PormG **can** express one: the column imports
as `db_default=` carrying exactly the text shown, so `detail` is the value to paste into your model.
Two things are worth knowing about such a column, and they are why the class still earns its place:

  * declaring it as `default=` instead is the one response that causes damage — that makes
    `makemigrations` propose `SET DEFAULT '<the expression>'`, a quoted literal written over the
    database's real expression default, after which every new row stores that text;
  * unless the expression is one of the portable ones (`CURRENT_TIMESTAMP`, `CURRENT_DATE`) it
    is **pinned to this engine**. A models file carrying it renders here and raises a
    `BackendCapabilityError` on the other backend, which is deliberate — PormG will not guess a
    translation — but it means a portable app needs `db_default = (postgres = …, sqlite = …)`
    spelled out.

**Re-scoped rather than retired (#496).** The detected set is unchanged; what changed is that the
finding now says how to describe the column rather than that it cannot be described.

A **primary key that imports as an `IDField` is deliberately not reported** — a `serial`/`bigserial`
`id` column, say. `sIDField` has neither a `default` that could hold an expression
(`Union{Int64, Nothing}`) nor a `db_default` slot at all: PostgreSQL rejects a column that is both
`GENERATED … AS IDENTITY` and carries a `DEFAULT`, so #496 could not give it one. There is
therefore nothing a model could declare there, and reporting it would be advice that cannot be
followed. (That a pre-existing `serial` key is not byte-identical to what PormG would emit is a
separate matter, and `makemigrations` already proposes the `IDENTITY` alteration for it.)

**That skip is wider than "an integer key", and the width is the point.** Any key on the fall-through
arm compiles to an `IDField` — a `BLOB`, a `REAL`, a `numeric` — with the sole exception of a
lengthless `TEXT` key on SQLite, which becomes `UUIDField(primary_key = true)`. `check` asks
`_arm_carries_db_default`, the same predicate the importer's arm selection implies, so the two
cannot disagree about it. Before #496 widened it the skip was integer-only, which was correct for
the OLD message ("declare no `default=` here", true of every key) and wrong for the new one: a
`BLOB PRIMARY KEY DEFAULT (randomblob(16))` was reported and told to declare a `db_default=` that
`IDField` warns about and ignores. Found in review.

A key that imports as a `UUIDField`, a `CharField` or a relation IS reported, because those arms
carry the expression and their spelling is worth showing.

This is the diagnostic a warning cannot be. Since #496 the importer emits **no** warning for these
columns — there is nothing being lost to warn about — so `check` is the only way to ask the question
without reading a generated models file, and the only one that works before you have generated one.

```julia
julia> PormG.Migrations.check("db_2")
Schema Check (postgres):
  2 finding(s)

  expression_default (2)
    ⚠ lap_note.created_at  DEFAULT now()
    ⚠ lap_note.note  DEFAULT concat('a'::text, 'b'::text)
      the DEFAULT is a SQL expression; it imports as `db_default=` with exactly this text. Declare it that way and NOT as `default=`, which would render it as a quoted literal
```

# `:invalid_index`

An index whose `pg_index.indisvalid` is false. The usual source is a `CREATE INDEX CONCURRENTLY` or
`REINDEX CONCURRENTLY` that failed part way (a duplicate value under a `UNIQUE` build, a deadlock, a
cancelled statement), often inside a [`run_once`](@ref) step with `transaction = false`.
PostgreSQL never uses such an index for queries, yet it still costs on writes, and a unique one may
still reject duplicates. An index being built `CONCURRENTLY` right now reads as invalid too,
until the build finishes.

One finding per index, on any table the other classes read, whatever its shape: `table` is the
table, `columns` is empty, `detail` the index name, and `message` the consequence, the remedy and the
index definition. The remedy always leads with `DROP INDEX CONCURRENTLY`, quoted and schema-qualified
so it pastes as is. A `REINDEX INDEX CONCURRENTLY` alternative (PostgreSQL 12 or later) is offered
as something to run once the cause is gone — a unique build that failed on duplicates fails the same
way again — and never for a `<name>_ccnew` / `<name>_ccold` copy a failed `REINDEX CONCURRENTLY` left
behind: drop that copy and do not re-create it, since the original (or the rebuilt index) is
already in place, and reindexing it would make a valid duplicate.

**It reports; it never acts.** `makemigrations` neither reads nor drops an invalid index (#847): a
field declaring `db_index = true` over a column carrying only an invalid index gets PormG's own index
beside it, and the invalid one stays until you drop it. Rebuilding or dropping it is your decision,
because only you know whether the failed build is still wanted.

```julia
julia> PormG.Migrations.check("db_2"; kinds = [:invalid_index])
Schema Check (postgres):
  1 finding(s)

  invalid_index (1)
    ⚠ driver  driver_code_uq — invalid index: PostgreSQL never uses it for queries, but it still takes disk space and keeps updates to its columns from being HOT. One still being built CONCURRENTLY reads the same until it finishes. Usually a failed CREATE INDEX CONCURRENTLY. Drop it with `DROP INDEX CONCURRENTLY "public"."driver_code_uq";`, remove what made the build fail (for a unique index, usually duplicate values), and create it again from the definition below; on PostgreSQL 12 or later, `REINDEX INDEX CONCURRENTLY "public"."driver_code_uq";` rebuilds it in place instead, once the cause is gone. Definition: CREATE UNIQUE INDEX driver_code_uq ON public.driver USING btree (code)
```

See also [`SchemaCheckResult`](@ref), [`SchemaCheckFinding`](@ref).
"""
function check(connection::Union{PormGPostgres, PormGSQLite}, settings::PormGSettings;
               kinds::AbstractVector{Symbol} = [:expression_default],
               ignore_table::Union{Vector{String}, Nothing} = nothing,
               include_table::Union{Vector{String}, Nothing} = nothing,
               models_file::Union{AbstractString, Nothing} = nothing)::SchemaCheckResult
  _validate_check_kinds(kinds, models_file)
  # #818: the default this connection reads with, less its `unignore_defaults:` entries.
  default_ignore = _backend_ignore_tables(connection, settings)
  # #749: a caller's `ignore_table` replaces the backend default only; the connection's own
  # `ignore_tables:` is always added on top, like the registry.
  base_ignore = _with_connection_ignores(something(ignore_table, default_ignore), settings)
  findings = SchemaCheckFinding[]

  if :expression_default in kinds
    ignore = unique(vcat(base_ignore, _EXTRA_IGNORE_TABLES[]))
    if connection isa PormGSQLite
      append!(findings, _sqlite_expression_default_findings(connection; ignore_table = ignore,
                                                            include_table = include_table))
    else
      schemas = get_database_schema(connection)
      if include_table !== nothing
        schemas = filter(r -> any(included -> r.table_name == included, include_table), schemas)
      end
      append!(findings, _pg_expression_default_findings(schemas; ignore_table = ignore))
    end
  end

  # SQLite has no invalid-index state, so the class reports nothing there rather than raising: a
  # `kinds` list shared by both engines' gates must not fail on one of them.
  if :invalid_index in kinds && connection isa PormGPostgres
    ignore = unique(vcat(base_ignore, _EXTRA_IGNORE_TABLES[]))
    append!(findings, _pg_invalid_index_findings(connection; ignore_table = ignore,
                                                 include_table = include_table))
  end

  if :schema_drift in kinds
    # The reader adds `_EXTRA_IGNORE_TABLES` itself, exactly as it does for `makemigrations`.
    append!(findings, _schema_drift_findings(connection, settings;
                                             ignore_table = base_ignore,
                                             include_table = include_table, models_file = models_file))
  end

  return SchemaCheckResult(connection isa PormGSQLite ? :sqlite : :postgres, _sort_findings(findings))
end

function check(settings::PormGSettings; kwargs...)::SchemaCheckResult
  check(settings.connections, settings; kwargs...)
end

function check(db::String; config::Dict{String,PormGSettings} = config, kwargs...)::SchemaCheckResult
  settings = config[db]
  check(settings; kwargs...)
end

# ==============================================================================
# Core Execution Engine — unified lifecycle for both PostgreSQL and SQLite
# ==============================================================================

"""
    _execute_statements_pg(connection, statements; conn) -> Nothing

Execute a list of SQL statements on a PostgreSQL connection within a transaction.
Each plan entry is cut by [`_split_pg_statements`](@ref) first and sent one statement per call,
whichever driver holds the connection (#841). A plan entry can hold several statements —
`alter_field` joins every change to one column, `add_check_constraint` adds the constraint and its
marker comment — and only LibPQ accepts that in one call: it sends a parameterless string over the
simple query protocol, while Postgres.jl prepares every statement it is given and PostgreSQL refuses
a prepared statement holding more than one command (`42601`). Both drivers take the same path so the
LibPQ suite exercises it too. Atomicity is unchanged: every call runs on `conn`, inside the
migration's one transaction. The whole plan is cut before the first call, so a plan the splitter
refuses runs none of its statements.
"""
function _execute_statements_pg(connection::PormGPostgres, statements::Vector{String}; conn)
  parts = String[part for action in statements for part in _split_pg_statements(action)]
  for part in parts
    @debug "Executing: $part"
    with_transaction(connection, part, conn=conn)
  end
end

# PostgreSQL's identifier characters, for the dollar-quote rules below: a tag is made of them, and a
# `$` right after one belongs to that identifier (`a$b`) rather than opening a quote.
_pg_ident_start(c::Char) = isletter(c) || c == '_' || c > '\x7f'
_pg_ident_char(c::Char) = _pg_ident_start(c) || isdigit(c) || c == '$'

# The dollar-quote delimiter (`$$`, `$tag$`) opening at `cs[i]`, or `nothing` when that `$` opens none:
# a positional parameter (`$1`), or a `$` inside an identifier.
function _pg_dollar_tag(cs::Vector{Char}, i::Int)::Union{String, Nothing}
  (i > 1 && _pg_ident_char(cs[i - 1])) && return nothing
  n = length(cs)
  j = i + 1
  if j <= n && _pg_ident_start(cs[j])
    while j <= n && _pg_ident_char(cs[j]) && cs[j] != '$'
      j += 1
    end
  end
  (j <= n && cs[j] == '$') || return nothing
  return String(cs[i:j])
end

# Raised for a literal, quoted identifier, dollar quote or block comment that never closes: everything
# after it would read as quoted, so a cut there would run a fragment and nothing would say so.
function _pg_unterminated(cs::Vector{Char}, i::Int, what::AbstractString)
  throw(InvalidMigrationError(
    "This migration has an unterminated $(what), so where its statements end cannot be found and " *
    "none of them is run; close it: $(strip(String(cs[i:min(length(cs), i + 79)]))) …"))
end

# The index just past the string literal, quoted identifier, dollar quote or comment that opens at
# `cs[i]`, or `i` itself when none does. PostgreSQL's lexical rules, which are not SQLite's: block
# comments nest, `E'…'` takes backslash escapes, and `$tag$ … $tag$` quotes anything but its own tag,
# with no escape at all. A string literal or quoted identifier escapes its own quote by doubling. A
# `--` comment runs to the end of the line — `\n` or `\r`, as PostgreSQL's lexer has it — or of the text.
function _pg_lex_skip(cs::Vector{Char}, i::Int)::Int
  n = length(cs)
  c = cs[i]
  if c == '-' && i < n && cs[i + 1] == '-'
    while i <= n && cs[i] != '\n' && cs[i] != '\r'
      i += 1
    end
    return i
  elseif c == '/' && i < n && cs[i + 1] == '*'
    from, depth = i, 1
    i += 2
    while i < n
      if cs[i] == '/' && cs[i + 1] == '*'
        depth += 1
        i += 2
      elseif cs[i] == '*' && cs[i + 1] == '/'
        depth -= 1
        i += 2
        depth == 0 && return i
      else
        i += 1
      end
    end
    _pg_unterminated(cs, from, "/* comment")
  elseif c == '\'' || c == '"'
    # `E'…'`: the `E` must be a token of its own, or it is the end of an identifier (`name'…'`).
    backslash = c == '\'' && i > 1 && cs[i - 1] in ('E', 'e') && (i == 2 || !_pg_ident_char(cs[i - 2]))
    from = i
    i += 1
    while i <= n
      if backslash && cs[i] == '\\'
        i += 2
      elseif cs[i] == c && i < n && cs[i + 1] == c
        i += 2
      elseif cs[i] == c
        return i + 1
      else
        i += 1
      end
    end
    _pg_unterminated(cs, from, c == '"' ? "quoted identifier" : "string literal")
  elseif c == '$'
    tag = _pg_dollar_tag(cs, i)
    tag === nothing && return i
    t = collect(tag)
    k = i + length(t)
    while k + length(t) - 1 <= n
      cs[k:k + length(t) - 1] == t && return k + length(t)
      k += 1
    end
    _pg_unterminated(cs, i, "dollar quote ($(tag))")
  end
  return i
end

"""
    _split_pg_statements(sql) -> Vector{String}

`sql` cut into the statements it holds, each without its terminating `;`, for a driver that runs one
statement per call (#841). Statements holding nothing but whitespace and comments are dropped.

A `;` ends a statement only outside a string literal (`'…'`, `E'…'`), a quoted identifier, a
dollar quote (`\$\$ … \$\$`, `\$tag\$ … \$tag\$`), a comment (`--`, and `/* … */`, which nests on
PostgreSQL) and parentheses — psql's own rule, which keeps a `CREATE RULE … DO (…; …)` whole. The
plan text is PormG's own, but a `;` still reaches it legitimately inside a `SET DEFAULT '…'`
literal, a CHECK condition, or the DBA comment a CHECK adoption keeps. A plain `'…'` is read with
`standard_conforming_strings = on`, the setting every other quote PormG renders already assumes.

One shape psql recognizes is not: a SQL-standard `BEGIN ATOMIC … END` function body, which PormG never
renders. A hand-written one in a pending plan is cut inside its body, and the server refuses the
fragment, so the migration fails and rolls back rather than half-applying.

**It fails closed.** One of those that never closes raises `InvalidMigrationError`: everything after
it would be read as quoted, so the cut would run a fragment and nothing would say so. An unclosed
parenthesis raises too. The SQLite twin
is [`_split_sqlite_statements`](@ref), which reads SQLite's rules instead.
"""
function _split_pg_statements(sql::AbstractString)::Vector{String}
  cs = collect(sql)
  n = length(cs)
  statements = String[]
  start, content, depth = 1, false, 0
  i = 1
  while i <= n
    c = cs[i]
    j = _pg_lex_skip(cs, i)
    if j != i
      # A comment is not content; a literal, a quoted identifier or a dollar quote is.
      (c == '-' || c == '/') || (content = true)
      i = j
    elseif c == ';' && depth == 0
      text = strip(String(cs[start:i - 1]))
      content && !isempty(text) && push!(statements, text)
      start, content = i + 1, false
      i += 1
    else
      c == '(' && (depth += 1)
      c == ')' && (depth = max(depth - 1, 0))
      isspace(c) || (content = true)
      i += 1
    end
  end
  # An unclosed `(` would carry every statement after it into one call, which Postgres.jl refuses
  # with a 42601 that names the wrong cause; say what is wrong instead.
  depth > 0 && _pg_unterminated(cs, start, "parenthesis")
  text = strip(String(cs[start:n]))
  content && !isempty(text) && push!(statements, text)
  return statements
end

# The index just past the string literal, quoted identifier or comment that opens at `cs[i]`, or `i`
# itself when none does. SQLite's lexical rules, the same ones `_sqlite_identifier_tokens` scans by:
# `'…'` / `"…"` / `` `…` `` escape their own quote by doubling it, `[…]` has no escape, and there is
# no backslash escape anywhere. An unterminated one runs to the end, as SQLite reads it.
function _sqlite_lex_skip(cs::Vector{Char}, i::Int)::Int
  n = length(cs)
  c = cs[i]
  if c == '-' && i < n && cs[i + 1] == '-'
    while i <= n && cs[i] != '\n'
      i += 1
    end
    return i
  elseif c == '/' && i < n && cs[i + 1] == '*'
    i += 2
    while i < n && !(cs[i] == '*' && cs[i + 1] == '/')
      i += 1
    end
    return min(i + 2, n + 1)
  elseif c == '\'' || c == '"' || c == '`'
    i += 1
    while i <= n
      if cs[i] == c && i < n && cs[i + 1] == c
        i += 2
      elseif cs[i] == c
        return i + 1
      else
        i += 1
      end
    end
    return n + 1
  elseif c == '['
    while i <= n && cs[i] != ']'
      i += 1
    end
    return min(i + 1, n + 1)
  end
  return i
end

_sqlite_opens_comment(cs::Vector{Char}, i::Int) =
  i < length(cs) && ((cs[i] == '-' && cs[i + 1] == '-') || (cs[i] == '/' && cs[i + 1] == '*'))

# Whether the `/* … */` comment opening at `cs[i]` is never closed. SQLite accepts one at the end of
# its input and stores it as written, so a definition read back from `sqlite_master` can carry one.
_sqlite_block_comment_open(cs::Vector{Char}, i::Int)::Bool =
  !any(k -> cs[k] == '*' && cs[k + 1] == '/', (i + 2):(length(cs) - 1))

# The index of the next character at or after `i` that is neither whitespace nor inside a comment,
# or `length(cs) + 1` when there is none.
function _sqlite_next_significant(cs::Vector{Char}, i::Int)::Int
  n = length(cs)
  while i <= n
    if isspace(cs[i])
      i += 1
    elseif _sqlite_opens_comment(cs, i)
      i = _sqlite_lex_skip(cs, i)
    else
      return i
    end
  end
  return n + 1
end

# `CREATE TRIGGER` and `CREATE TEMP|TEMPORARY TRIGGER`, read off a statement's leading bare words.
_sqlite_leads_create_trigger(lead::Vector{String}) =
  length(lead) >= 2 && lead[1] == "CREATE" &&
  (lead[2] == "TRIGGER" || (length(lead) >= 3 && lead[2] in ("TEMP", "TEMPORARY") && lead[3] == "TRIGGER"))

"""
    _split_sqlite_statements(sql) -> Vector{String}

`sql` cut into the statements SQLite executes one at a time, each without its terminating `;`.
Statements holding nothing but whitespace and comments are dropped.

A `;` inside a string literal, a quoted identifier or a comment does not end a statement, and
neither does one inside a `CREATE TRIGGER … BEGIN … END` body (#729). A trigger body is a list of
statements, each ending in its own `;`, and it arrives here verbatim whenever a SQLite table rebuild
re-creates the triggers the rebuild's `DROP TABLE` takes with it. Cutting it at the first `;` hands
SQLite a fragment it rejects as incomplete input.

The body's end is an `END` that directly follows a `;` and is directly followed by the statement's
`;` or by the end of the text — `sqlite3_complete`'s own rule. Every body statement ends in `;` and
none can begin with `END`, so that pair is only ever the body's end: a `CASE … END` closes inside an
expression, and a column called `end` (`ORDER BY end;`) is never preceded by `;`. The header's `BEGIN`
is the first one after the `ON <table>` clause and outside parentheses, which keeps a column named
`begin` in `UPDATE OF begin ON t` from opening the body. A word right after a `.` is a column
(`NEW.end`), never a keyword, and a word runs over every character from U+0080 up as SQLite's does —
so `x·case` is one identifier, not an `x` and a `CASE`.

**It fails closed, and that is load-bearing.** SQLite.jl prepares a statement with a null tail, so
text that holds two statements runs the FIRST one and silently discards the rest. A trigger whose
end is never found would swallow every statement after it, including the rebuild's
`PRAGMA foreign_key_check` gate. So a `CREATE TRIGGER` that reaches the end of the text still open
raises `InvalidMigrationError`. The opposite mistake, an `END` read as the body's end too early, is
loud already, because SQLite rejects the truncated trigger. For the same reason an unterminated
`/* …` comment that contains a `;` raises too: everything after it is comment, so the statements it
swallowed would never run and nothing would say so.

There used to be a backslash escape here, and it is gone on purpose: SQLite has none, so
`'C:\\'` is a complete literal and the old rule read everything after it as still quoted.
"""
function _split_sqlite_statements(sql::AbstractString)::Vector{String}
  cs = collect(sql)
  n = length(cs)
  statements = String[]
  # The state of the statement being read. All of it resets at every cut.
  start = 1              # its first character
  content = false        # has it held anything but whitespace and comments?
  lead = String[]        # its first three tokens: bare words uppercased, anything else ""
  phase = :plain         # :plain, or a trigger's :header → :body → :done
  seen_on = false        # header: the `ON <table>` clause has been read
  depth = 0              # header: parenthesis depth
  prev = ' '             # the last significant character; '.' marks a qualified word, ';' a body
                         # statement's end
  i = 1
  while i <= n
    c = cs[i]
    j = _sqlite_lex_skip(cs, i)
    if j != i
      if cs[i] == '/' && j > n && _sqlite_block_comment_open(cs, i) && ';' in cs[i:n]
        throw(InvalidMigrationError(
          "An unterminated /* comment in this migration swallows every statement after it, so none " *
          "of them would run and nothing would say so; the migration stops here instead. Close the " *
          "comment: $(strip(String(cs[i:min(n, i + 79)]))) …"))
      end
      # A comment is not content. A literal or a quoted identifier is, and it is a token that is
      # not a keyword, which is all `lead` needs to know about it.
      if !_sqlite_opens_comment(cs, i)
        content = true
        length(lead) < 3 && push!(lead, "")
        prev = 'a'
      end
      i = j
    elseif isspace(c)
      i += 1
    elseif c == ';'
      if phase === :header || phase === :body
        prev = ';'
        i += 1
        continue
      end
      text = strip(String(cs[start:i - 1]))
      content && !isempty(text) && push!(statements, text)
      start, content, lead, phase = i + 1, false, String[], :plain
      seen_on, depth, prev = false, 0, ' '
      i += 1
    elseif isletter(c) || c == '_' || c > '\x7f'
      from = i
      while i <= n && (isletter(cs[i]) || isdigit(cs[i]) || cs[i] == '_' || cs[i] == '$' || cs[i] > '\x7f')
        i += 1
      end
      word = uppercase(String(cs[from:i - 1]))
      content = true
      if length(lead) < 3
        push!(lead, word)
        phase === :plain && _sqlite_leads_create_trigger(lead) && (phase = :header)
      end
      if prev != '.'
        if phase === :header && depth == 0
          if word == "ON"
            seen_on = true
          elseif word == "BEGIN" && seen_on
            phase = :body
          end
        elseif phase === :body && word == "END" && prev == ';'
          k = _sqlite_next_significant(cs, i)
          (k > n || cs[k] == ';') && (phase = :done)
        end
      end
      prev = 'a'
    elseif isdigit(c)
      # A numeric literal, consumed whole so `1e5` leaves no word behind.
      while i <= n && (isletter(cs[i]) || isdigit(cs[i]) || cs[i] == '_' || cs[i] == '.')
        i += 1
      end
      content = true
      prev = '0'
    else
      c == '(' && (depth += 1)
      c == ')' && (depth = max(depth - 1, 0))
      content = true
      prev = c
      i += 1
    end
  end
  if phase === :header || phase === :body
    head = strip(String(cs[start:min(n, start + 79)]))
    throw(InvalidMigrationError(
      "A CREATE TRIGGER statement in this migration has no terminating END, so where it stops " *
      "cannot be found. SQLite would run it and silently skip every statement after it, so the " *
      "migration stops here instead. Check its BEGIN … END body: $(head) …"))
  end
  text = strip(String(cs[start:n]))
  content && !isempty(text) && push!(statements, text)
  return statements
end

"""
    _execute_statements_sqlite(connection, statements; conn) -> Nothing

Execute a list of SQL statements on a SQLite connection within a transaction.
SQLite executes one statement per call, so each plan entry is cut by
[`_split_sqlite_statements`](@ref) first.
"""
function _execute_statements_sqlite(connection::PormGSQLite, statements::Vector{String}; conn)
  for action in statements
    parts = _split_sqlite_statements(action)
    for part in parts
      trimmed = strip(part) |> string
      isempty(trimmed) && continue
      @debug "Executing: $trimmed"
      if occursin(r"^PRAGMA\s+foreign_key_check"i, trimmed)
        # #82: gate emitted by the SQLite table-rebuild. foreign_key_check returns one row per orphaned
        # FK reference; any rows mean the rebuild left dangling children, so abort — the surrounding
        # catch rolls the whole migration back. (PRAGMA foreign_key_check works inside a transaction,
        # unlike PRAGMA foreign_keys.)
        result, _ = with_transaction(connection, trimmed, conn=conn)
        violations = DataFrame(result)
        if nrow(violations) > 0
          throw(InvalidMigrationError("Migration aborted: PRAGMA foreign_key_check found $(nrow(violations)) orphaned foreign-key row(s) after a SQLite table rebuild; rolling back."))
        end
      else
        with_transaction(connection, trimmed, conn=conn)
      end
    end
  end
end

"""
    _archive_migration_files(settings, date_str) -> Nothing

Move pending_migrations.jl to applied_migrations/ and snapshot the models file.
"""
function _archive_migration_files(settings::PormGSettings, date_str::String)
  # Nothing to archive when the plan is already gone (#737): several instances booting from one
  # shared folder all read the same `pending_migrations.jl`, and the first to finish moves it. The
  # others then report `:already_applied`, and must not leave an orphan `_old_models.jl` snapshot
  # beside an archive they did not write.
  isfile(_pending_plan_path(settings)) || return nothing

  path_applied = joinpath(settings.db_def_folder, "migrations", "applied_migrations")
  if !ispath(path_applied)
    mkpath(path_applied)
  end
  
  target_migration = joinpath(path_applied, "$(date_str)_migration.jl")
  while isfile(target_migration)
    suffix = string(rand(1000:9999))
    target_migration = joinpath(path_applied, "$(date_str)_$(suffix)_migration.jl")
  end
  
  mv(_pending_plan_path(settings), target_migration)

  final_date_str = replace(basename(target_migration), "_migration.jl" => "")
  models_path = _snapshot_models_path(settings, target_migration)
  if models_path !== nothing && isfile(models_path)
    cp(models_path, joinpath(path_applied, "$(final_date_str)_old_models.jl"), force=true)
  end
  return nothing
end

# Which models file to snapshot beside an archived plan (#736): the one its header names, else the
# connection's own. `nothing`, after a warning, when the header cannot be used — unreadable (a
# hand-written value `escape_string` never encoded), no digest, the file gone, or its bytes no longer
# the ones the plan was generated from. Never the default instead: a snapshot of a file the plan was
# not diffed against is the defect the header exists to prevent. Read from the ARCHIVED plan, after
# the move, so nothing here can leave an applied plan behind as pending.
function _snapshot_models_path(settings::PormGSettings, plan_path::String)::Union{String, Nothing}
  recorded = try
    _plan_models_file(settings, plan_path)
  catch e
    @warn "The migration was applied, but its plan's models-file header could not be read, so no models snapshot was archived." plan = plan_path exception = e
    return nothing
  end
  recorded === nothing && return joinpath(settings.db_def_folder, settings.model_file)
  if !(recorded.sha256 !== nothing && isfile(recorded.path) && _models_file_digest(recorded.path) == recorded.sha256)
    @warn "The migration was applied, but the models file its plan was generated from is gone or has changed since, so no models snapshot was archived." models_file = recorded.path
    return nothing
  end
  return recorded.path
end

# The `# pormg-models-file:` header `makemigrations` writes when the plan was diffed against a file
# other than the connection's own models file (#736), with the digest line below it — `(path,
# sha256)`, or `nothing` when the header is absent; `sha256` is `nothing` when its line is missing.
# Read by line scan, like the format marker, because `_read_migration_plan` parses the plan as data
# and `Meta.parseall` drops comments. A relative path is relative to `db_def_folder`, so a plan
# generated beside its models file still resolves from another cwd. Throws on a value
# `unescape_string` rejects; `_snapshot_models_path` owns that case.
function _plan_models_file(settings::PormGSettings, plan_path::String = _pending_plan_path(settings))
  path = nothing
  sha256 = nothing
  # `open(...) do`, not `eachline(plan_path)`: a filename `eachline` closes its handle only when the
  # iteration runs to the end, and this loop breaks early — the handle then lives until GC, and on
  # Windows an open handle makes every later `rm`/`mv` of the archived plan fail with EBUSY.
  open(plan_path) do io
    for line in eachline(io)
      # The header block ends at the plan's first `import`; nothing below it is a header.
      startswith(line, "import ") && break
      m = match(MODELS_FILE_HEADER_RE, line)
      if m !== nothing
        p = unescape_string(m.captures[1])
        path = isabspath(p) ? p : joinpath(settings.db_def_folder, p)
        continue
      end
      d = match(MODELS_SHA256_HEADER_RE, line)
      d === nothing || (sha256 = String(d.captures[1]))
    end
  end
  return path === nothing ? nothing : (path = path, sha256 = sha256)
end

# ==============================================================================
# Main migrate() — unified lifecycle
# ==============================================================================

"""
    migrate(connection::PormGBackend, settings; interactive, destructive, name, lock_wait, lock_timeout, statement_timeout) -> MigrationResult
    migrate(db::String; config, kwargs...) -> MigrationResult

Apply the pending migration plan (`pending_migrations.jl`) to a database, PostgreSQL or SQLite, and
return a [`MigrationResult`](@ref) saying what happened. Safe to call at application boot by
several instances at once — see the [Deploying](@ref deploying-migrations) guide.

# Lifecycle
1. Validate: `change_db`, then read and order the plan from disk and detect destructive statements.
   **Nothing is written to the database before step 3.**
2. Confirm: the schema precondition (#739 — the tables the plan header records are read again and
   compared, and a difference raises [`PlanPreconditionError`](@ref); skipped for the #81 case
   below), then the lossy-ALTER row pre-check (#803 — a read-only count, refused whatever
   `destructive` says), then the destructive guard + interactive confirmation (TTY-aware — see
   `_confirm_migration`). Before the lock, so a prompt waiting on a human never holds it.
3. Lock (PostgreSQL): the advisory lock `MIGRATION_LOCK_KEY`, waited on for up to `lock_wait`.
   Everything below runs while it is held (#737).
4. Bootstrap: create `pormg_migrations` if needed and install configured extensions — also when
   nothing is pending.
5. Execute: skip a plan whose checksum is the latest applied migration (#81); otherwise check the
   schema precondition again — this is the check that decides, since another instance may have
   changed the schema since step 2 — then run the plan and record it in `pormg_migrations`, in one
   transaction. A refusal writes no `failed` row: no statement was attempted.
6. Archive: move the plan to `applied_migrations/`.

SQLite has no advisory lock, so steps 4–6 run unlocked there; its #81 check and the deciding
precondition run inside the `BEGIN IMMEDIATE` write transaction instead, so two processes that race
on one file cannot both apply the same plan, nor change a table between the check and the apply.

A plan with no `# pormg-schema-table:` header — one generated before #739, or one whose lines were
deleted on purpose — is applied without the precondition.

# Keywords
- `interactive::Bool=true`: prompt for confirmation before applying — **only when stdin is a real
  terminal**. In a non-interactive process (CI, `Pkg.test`, deploy script) no prompt is shown and
  `migrate()` never blocks on `readline()`.
- `destructive::Bool=false`: must be `true` to apply a plan `is_destructive` flags — any `DROP` (table,
  column, constraint, index, view, …), a `TRUNCATE`, or a `DELETE` with no `WHERE` — or one whose
  header records a column change that silently alters existing values (a lower `decimal_places`,
  float to integer, timestamp to date; see [`LOSSY_ALTER_KINDS`](@ref)). A destructive plan in a
  non-interactive context throws `DestructiveMigrationError` unless this is set. It does **not**
  get past a column change that would fail on existing rows: that is `MigrationPrecheckError`.
- `name::String="pending_migration"`: name for this migration in the history table.
- `lock_wait::Real=30`: seconds to wait for another instance's migration to finish (PostgreSQL). On
  timeout `migrate` throws `OperationalError`, naming the process that holds the lock.
- `lock_timeout::Union{Real,Nothing}=nothing`: seconds a plan statement may wait for a table lock
  before the migration fails and rolls back (PostgreSQL `SET LOCAL lock_timeout`). Without it, an
  `ALTER` queued behind a long-running query waits — and blocks every query on that table — for as
  long as that query runs.
- `statement_timeout::Union{Real,Nothing}=nothing`: seconds any one plan statement may run before
  the migration fails and rolls back (PostgreSQL `SET LOCAL statement_timeout`).

The three timeouts are PostgreSQL-only, and SQLite accepts and ignores them, so one deploy script
can run on either engine. Each must be a positive number of seconds.

Use [`dry_run`](@ref) to inspect a plan without applying it.
"""
function migrate(connection::PormGBackend, settings::PormGSettings;
                 interactive::Bool = true,
                 destructive::Bool = false,
                 name::String = "pending_migration",
                 lock_wait::Real = 30,
                 lock_timeout::Union{Real, Nothing} = nothing,
                 statement_timeout::Union{Real, Nothing} = nothing)::MigrationResult
  # --- Phase 1: Validate. Nothing here writes to the database. ---
  # First of all, because the folder is where the plan is read from (#683).
  Configuration._require_folder_backed(settings, "migrate")
  # Before the change_db return, so a bad value fails on every connection, not only on the ones
  # that happen to migrate.
  timeouts = _migration_timeouts(lock_wait, lock_timeout, statement_timeout)
  if !settings.change_db
    @warn("The database is not set to change_db, so the migration plan will not be applied.")
    return MigrationResult(:disabled, nothing, 0)
  end

  # Read the plan BEFORE any database write (#737). It used to be read after `init_migrations` and
  # the extension install, so a plan that did not parse — or was not there at all — failed only
  # after both had already written. "Not there" is now an empty plan, answered `:nothing_pending`
  # once the history table and the extensions are ensured, instead of the same
  # `InvalidMigrationError` a corrupt plan raises: a boot script has to be able to tell them apart.
  ordered_statements, all_sql = isfile(_pending_plan_path(settings)) ?
    _order_statements(_load_migration_plan(settings)) : (String[], "")

  version = generate_version()
  checksum = compute_checksum(all_sql)
  destructive_stmts = detect_destructive_actions(ordered_statements)
  # #803: the lossy column changes `makemigrations` recorded in the plan header. The SQL alone cannot
  # say what a column held before, so the header is the only source; a plan without one has none.
  lossy_alters = isempty(ordered_statements) ? LossyAlter[] :
    _anchor_check_conditions(_plan_lossy_alters(_pending_plan_path(settings)), settings)
  # #739: the schema the plan was generated against, read here so a damaged header is refused before
  # anything is written. `nothing` for a plan without one, which applies without the check.
  schema_tables = isempty(ordered_statements) ? nothing : _plan_schema_tables(_pending_plan_path(settings))

  # --- Phase 2: Confirm, BEFORE the lock (#737). A prompt waits on a human; holding the migration
  # lock meanwhile would stall every other instance booting against this database. TTY-aware:
  # never blocks on readline() without a terminal, and throws in the non-interactive destructive
  # case so automation fails loudly (see `_confirm_migration`).
  #
  # #803: the row pre-check runs first, and is not bypassed by `destructive = true`: a plan that
  # would fail on existing rows cannot be made to succeed by an opt-in, so it is refused before any
  # write rather than rolled back halfway through. It only READS, and only when the header records
  # something to count. The `:silent` findings then join the destructive guard's opt-in.
  #
  # #739: the schema precondition goes first of all. On a database the plan was not generated
  # against, the pre-check would count rows in columns that are not what the plan assumes — or are
  # not there — and the prompt would ask a human to confirm a plan that cannot apply. This early read
  # refuses the common case before any of that; the check that decides runs again inside the lock,
  # after the #81 guard, because another instance can change the schema in between. The #81 case is
  # not refused here, for the same reason it is not refused there: a plan already applied has
  # changed its own tables. It goes on through the pre-check and the destructive guard below, as it
  # did before #739, and the lock then archives it as `:already_applied`.
  #
  # The schema is read FIRST and the history only when it differs. Read the other way round, a
  # second instance booting with the same plan could see no `applied` row, then see the first
  # instance's committed changes, and refuse a plan that is already applied. Both engines commit the
  # DDL and the history row together, so a schema read that saw the changes is followed by a history
  # read that sees the row.
  if schema_tables !== nothing
    drift = _schema_precondition_drift(connection, settings, schema_tables)
    isempty(drift) || _plan_is_latest_applied(connection, checksum) ||
      throw(_plan_precondition_error(drift, schema_tables))
  end
  isempty(lossy_alters) ||(lossy_alters = _precheck_lossy_alters(connection, lossy_alters; timeouts = timeouts))
  silent_alters = _silent_alters(lossy_alters)
  has_destructive = !isempty(destructive_stmts) || !isempty(silent_alters)
  if !isempty(ordered_statements)
    _refuse_failing_alters(lossy_alters; interactive = interactive) ||
      return MigrationResult(:declined, nothing, 0)
    _confirm_migration(has_destructive, destructive, destructive_stmts; interactive=interactive,
                       lossy_alters = silent_alters) ||
      return MigrationResult(:declined, nothing, 0)
  end

  # --- Phase 3: Lock, bootstrap, execute (advisory lock on PostgreSQL, direct on SQLite) ---
  return _run_locked_lifecycle(connection, settings, ordered_statements, all_sql,
                               version, name, checksum, has_destructive; timeouts = timeouts,
                               schema_tables = schema_tables)
end

# Whether `checksum` is the latest applied migration's — the #81 guard's question, asked outside
# the lock and without creating the history table, which `migrate` has not ensured yet at this point.
_plan_is_latest_applied(connection::Union{PormGPostgres, PormGSQLite}, checksum::String)::Bool =
  _migrations_table_exists(connection) && _latest_applied_checksum(connection) == checksum

# ==============================================================================
# Backend-specific execution wrapper. PostgreSQL serializes migrations with an advisory
# lock; SQLite is single-instance only (no lock). `_execute_migration_lifecycle` is itself
# already dialect-dispatched — this hook only decides whether to wrap it in a lock.
# ==============================================================================

"""
    MIGRATION_LOCK_KEY

The advisory-lock key `migrate()` serializes on, for **every** PostgreSQL configuration.

Deliberately carries no database qualifier. A PostgreSQL advisory lock is tagged
`(database OID, key)` — the database is already the lock's namespace, so two pools opened on one
database contend on this key and two pools on different databases cannot collide however identical
their key is. `test/integration/common_setup.jl` relies on the same property for the suite lock.

It used to be `"pormg_migrations_\$(db_def_folder)"`, which was worse than redundant: the folder name
is not database identity, so two config folders resolving to ONE database took two different locks
and migrated it concurrently — the exact guarantee the lock exists to provide, silently defeated
(#90).

Deriving the key from `host:port/dbname` instead was considered and rejected. One target has several
spellings — a `url:` DSN or discrete `host`/`hostaddr`/`port`/`database`, `localhost` vs `127.0.0.1`
vs a Unix socket (see `Configuration.VALID_CONNECTION_KEYS`) — so a string-built identity re-creates
the "several match conditions of different strength" failure class #550 removed from connection-key
binding. PostgreSQL's own scoping cannot be spelled wrong.
"""
const MIGRATION_LOCK_KEY = "pormg::migrations"

# Takes the settings it does not read, so the seam exists if lock identity ever has to become
# narrower than a database (a per-schema migration target would need it); callers stay unchanged.
_migration_lock_key(::PormGSettings)::String = MIGRATION_LOCK_KEY

function _run_locked_lifecycle(connection::PormGPostgres, settings::PormGSettings,
                               ordered_statements, all_sql, version, name, checksum, has_destructive;
                               timeouts::_MigrationTimeouts = _migration_timeouts(),
                               schema_tables::Union{AbstractDict{String, String}, Nothing} = nothing)
  lock_key = _migration_lock_key(settings)
  AdvisoryLock.with_advisory_lock(connection, lock_key; wait=true, timeout_ms=timeouts.lock_wait_ms) do
    _locked_migration(connection, settings, ordered_statements, all_sql,
                      version, name, checksum, has_destructive, timeouts; schema_tables = schema_tables)
  end
end

function _run_locked_lifecycle(connection::PormGSQLite, settings::PormGSettings,
                               ordered_statements, all_sql, version, name, checksum, has_destructive;
                               timeouts::_MigrationTimeouts = _migration_timeouts(),
                               schema_tables::Union{AbstractDict{String, String}, Nothing} = nothing)
  _locked_migration(connection, settings, ordered_statements, all_sql,
                    version, name, checksum, has_destructive, timeouts; schema_tables = schema_tables)
end

# Everything `migrate` writes, in the order it writes it — on PostgreSQL all of it inside the
# advisory lock (#737). The history-table DDL and the extension install used to run BEFORE the lock,
# on every call: N instances booting together each issued `CREATE TABLE IF NOT EXISTS` and, with
# unaccent configured, `CREATE OR REPLACE FUNCTION public.immutable_unaccent` concurrently. The
# latter can fail with PostgreSQL's "tuple concurrently updated", which surfaced as a misleading
# "Run this once as the database owner". Serialized here, the second instance finds the work done.
#
# The extension install stays ahead of the empty-plan return on purpose: `migrate` is the one
# change_db-gated home for that DDL, so it provisions extensions even when there is no schema diff
# (`docs/src/configuration/connection_yml.md`).
function _locked_migration(connection::Union{PormGPostgres, PormGSQLite}, settings::PormGSettings,
                           ordered_statements::Vector{String}, all_sql::String, version::String,
                           name::String, checksum::String, has_destructive::Bool,
                           timeouts::_MigrationTimeouts;
                           schema_tables::Union{AbstractDict{String, String}, Nothing} = nothing)::MigrationResult
  init_migrations(connection)
  Configuration._install_configured_extensions!(settings)

  if isempty(ordered_statements)
    @info(_emsg("\e[32mNo pending migrations — nothing to apply.\e[0m"))
    return MigrationResult(:nothing_pending, nothing, 0)
  end

  return _execute_migration_lifecycle(connection, settings, ordered_statements, all_sql,
                                      version, name, checksum, has_destructive, timeouts;
                                      schema_tables = schema_tables)
end

# `SET LOCAL` the opt-in timeouts on the migration transaction's connection (#737). LOCAL, so they
# end with the transaction and the connection goes back to the pool with its own settings. Each
# value is an `Int` PormG formatted (`_migration_timeout_ms`), never caller text.
function _set_local_timeouts!(connection::PormGPostgres, conn, timeouts::_MigrationTimeouts)
  timeouts.lock_timeout_ms === nothing ||
    with_transaction(connection, "SET LOCAL lock_timeout = '$(timeouts.lock_timeout_ms)ms';", conn=conn)
  timeouts.statement_timeout_ms === nothing ||
    with_transaction(connection, "SET LOCAL statement_timeout = '$(timeouts.statement_timeout_ms)ms';", conn=conn)
  return nothing
end

# ==============================================================================
# Shared execution lifecycle (called within lock for PostgreSQL)
# ==============================================================================

function _execute_migration_lifecycle(connection::PormGPostgres, settings::PormGSettings,
                                      ordered_statements::Vector{String}, all_sql::String,
                                      version::String, name::String, checksum::String,
                                      has_destructive::Bool,
                                      timeouts::_MigrationTimeouts = _migration_timeouts();
                                      schema_tables::Union{AbstractDict{String, String}, Nothing} = nothing)::MigrationResult
  date_str = Dates.format(Dates.now(), "yyyy-mm-dd_HH-MM-SS")

  # Idempotency guard (issue #81). Runs inside the advisory lock, so the check-and-skip is
  # serialized against any concurrent migrator. If the pending plan's checksum matches the latest
  # applied migration, this is a re-run over a `pending_migrations.jl` that a previous apply
  # COMMITted but then failed to archive — re-executing non-idempotent DDL (a plain ADD COLUMN /
  # ADD CONSTRAINT / CREATE INDEX) would error and leave a spurious `failed` row. Skip the DDL and
  # retry the archive so the stale pending file finally clears.
  latest = _latest_applied(connection)
  if latest !== nothing && String(latest[:checksum]) == checksum
    @info(_emsg("\e[32mMigration already applied (checksum match) — skipping re-apply.\e[0m"))
    try
      _archive_migration_files(settings, date_str)
    catch e
      @error "Error archiving already-applied migration files" exception=e
    end
    return MigrationResult(:already_applied, string(latest[:version]), 0)
  end

  # #739: the schema precondition that decides, inside the advisory lock and after the #81 guard — a
  # plan already applied has changed its own tables, so it is archived above, never refused here.
  # Before BEGIN, so a refusal writes no `failed` row: nothing was attempted. The lock serializes
  # every migrator, so no other plan can change these tables between this read and the BEGIN.
  schema_tables === nothing || _check_schema_precondition(connection, settings, schema_tables)

  # Begin transaction
  _, conn = with_transaction(connection, "BEGIN;")
  # Release/renew the transaction connection exactly once, in a single terminal finally, so a
  # failed COMMIT never returns it to the pool before the cleanup ROLLBACK has run on it (#139).
  local rollback_error = nothing

  try
    # Opt-in timeouts first, inside the transaction, so they bound every plan statement (#737).
    _set_local_timeouts!(connection, conn, timeouts)

    # Execute all SQL statements
    _execute_statements_pg(connection, ordered_statements; conn=conn)

    # Record in history table (within same transaction)
    _record_migration(connection, version, name, checksum, all_sql, "applied", has_destructive; conn=conn)

    # Commit — release_conn=false: the finally owns the single release.
    with_transaction(connection, "COMMIT;", conn=conn, release_conn=false)
    @info(_emsg("\e[32mMigrations applied successfully. Version: $version\e[0m"))
  catch e
    # Roll back on the still-leased connection. A rollback failure must not mask the body's
    # error — capture it so the finally renews/discards the (now-dirty) connection instead of
    # releasing it (#71), then rethrow the original.
    try
      with_transaction(connection, "ROLLBACK;", conn=conn, release_conn=false)
    catch rollback_err
      rollback_error = rollback_err
      @error "Failed to rollback transaction" exception=rollback_err
    end

    # Record failed status outside the (now rolled-back) transaction. Reuse the transaction's
    # own connection (conn=conn) rather than acquiring a fresh one: it is still leased until the
    # finally, and SQLite's single writer slot would otherwise deadlock this write. Trade-off: if
    # the ROLLBACK above ALSO failed, `conn` is dirty/aborted and this INSERT fails too (logged and
    # skipped, then the finally renews the connection) — so in that rare double-failure the `failed`
    # row is not recorded; the error is still logged and rethrown.
    try
      _record_migration(connection, version, name, checksum, all_sql, "failed", has_destructive; conn=conn)
    catch record_err
      @error "Failed to record migration failure in history table" exception=record_err
    end

    @error "Error applying migrations" exception=e
    rethrow(e)
  finally
    finalize_transaction_connection!(connection, conn; rollback_error=rollback_error)
  end

  # Archive files (post-commit, best-effort)
  try
    _archive_migration_files(settings, date_str)
  catch e
    @error "Error archiving migration files (migration was applied successfully)" exception=e
  end
  return MigrationResult(:applied, version, length(ordered_statements))
end

function _execute_migration_lifecycle(connection::PormGSQLite, settings::PormGSettings,
                                      ordered_statements::Vector{String}, all_sql::String,
                                      version::String, name::String, checksum::String,
                                      has_destructive::Bool,
                                      ::_MigrationTimeouts = _migration_timeouts();
                                      schema_tables::Union{AbstractDict{String, String}, Nothing} = nothing)::MigrationResult
  date_str = Dates.format(Dates.now(), "yyyy-mm-dd_HH-MM-SS")

  # Serialize the whole BEGIN..COMMIT against any concurrent SQLite writer, like
  # run_in_transaction/delete(). Migrations normally run sequentially at startup,
  # but if one is applied while app writes are in flight, two un-serialized
  # `BEGIN IMMEDIATE`s would race and deadlock the single async worker. No-op on
  # PostgreSQL. See ConnectionPool.with_sqlite_write_lock.
  #
  # The body returns the #81 guard's verdict: the matched history row when the plan was already
  # applied, `nothing` when this call applied it.
  already = with_sqlite_write_lock(connection) do
    # #276: acquire EXPLICITLY rather than letting `with_transaction` acquire at BEGIN. SQLite
    # ignores `PRAGMA foreign_keys` inside a transaction — silently, returning success — so
    # enforcement has to be suspended on this exact handle BEFORE the BEGIN. Acquired inside the
    # write lock to keep the lock→slot order `run_in_transaction` uses; the reverse order deadlocks
    # against it under split_read_write, where there is exactly one writer slot.
    conn = acquire_connection(connection; mode = :write)
    # Single terminal finally releases/renews the connection exactly once, so a failed COMMIT
    # never returns it to the pool before the cleanup ROLLBACK has run on it (#139).
    local rollback_error = nothing

    try
      # #276: the SQLite table-rebuild drops the old table, and with enforcement on that implicit
      # DELETE fires child ON DELETE actions — a CASCADE child's rows are deleted, the parent is
      # renamed back, and the migration COMMITs. The per-table `PRAGMA foreign_key_check` gate
      # cannot see it (after a cascade there are no orphans left, only missing children). This is
      # step 1 of SQLite's own documented ALTER procedure. `foreign_key_check` still works while
      # suspended, so the #82 gate keeps its full detection power.
      with_transaction(connection, "PRAGMA foreign_keys = OFF;", conn=conn)
      _assert_foreign_keys_suspended(connection, conn)

      # Begin transaction (IMMEDIATE for SQLite)
      with_transaction(connection, "BEGIN IMMEDIATE TRANSACTION;", conn=conn)

      # Inner try scoped to "a transaction is actually open" (#276). Kept separate from the outer
      # one on purpose: folding them together would make a failed PRAGMA or BEGIN run the ROLLBACK
      # and write a spurious `failed` history row for a transaction that never started.
      #
      # `attempted` narrows that once more: the #81 guard below also runs inside the transaction,
      # and a failure there is not a failed migration either — no plan statement has run.
      attempted = false
      try
        # Idempotency guard (issue #81) — see the PostgreSQL lifecycle for the full rationale. If
        # the pending plan's checksum matches the latest applied migration, this is a re-run over a
        # `pending_migrations.jl` a previous apply COMMITted but failed to archive; re-executing
        # non-idempotent DDL would error. Skip and retry the archive so the stale pending file clears.
        #
        # HERE, after `BEGIN IMMEDIATE`, and read on this transaction's own connection (#737). It
        # used to run before the write lock, which on SQLite is the only mutual exclusion there is:
        # two processes migrating one file could both pass it, and the second then re-ran the
        # first's DDL and recorded a `failed` row — or a duplicate `applied` row, when every
        # statement happened to be idempotent. Holding the write transaction, no other process can
        # commit between this read and our COMMIT.
        latest = _latest_applied(connection; conn = conn)
        if latest !== nothing && String(latest[:checksum]) == checksum
          with_transaction(connection, "ROLLBACK;", conn=conn, release_conn=false)
          return latest
        end

        # #739: the schema precondition, after the #81 guard for the reason given in the PostgreSQL
        # lifecycle, and inside `BEGIN IMMEDIATE` — the only mutual exclusion SQLite has — so no other
        # process can change these tables before our COMMIT. The read runs on this transaction's own
        # connection through `with_tx_context`: a `fetch(...; conn = conn)` would hand the connection
        # back to the pool mid-transaction (#139). A refusal leaves `attempted` false, so it rolls
        # back without a `failed` row.
        schema_tables === nothing || Configuration.with_tx_context(connection, conn) do
          _check_schema_precondition(connection, settings, schema_tables)
        end

        attempted = true
        # Execute all SQL statements
        _execute_statements_sqlite(connection, ordered_statements; conn=conn)

        # Record in history table (within same transaction)
        _record_migration(connection, version, name, checksum, all_sql, "applied", has_destructive; conn=conn)

        # Commit — release_conn=false: the finally owns the single release.
        with_transaction(connection, "COMMIT;", conn=conn, release_conn=false)
        @info(_emsg("\e[32mMigrations applied successfully. Version: $version\e[0m"))
        return nothing
      catch e
        # Roll back on the still-leased connection; capture a rollback failure so the finally
        # renews/discards the dirty connection instead of releasing it (#71), then rethrow.
        try
          with_transaction(connection, "ROLLBACK;", conn=conn, release_conn=false)
        catch rollback_err
          rollback_error = rollback_err
          @error "Failed to rollback transaction" exception=rollback_err
        end

        # Record failed status outside the (now rolled-back) transaction, reusing the transaction's
        # own connection (conn=conn): it is still leased until the finally, and acquiring a fresh
        # writer would deadlock on SQLite's single writer slot. Trade-off: if the ROLLBACK above also
        # failed, `conn` is dirty and this INSERT fails too (logged and skipped, then the finally
        # renews it) — so the `failed` row is not recorded in that rare double-failure.
        if attempted
          try
            _record_migration(connection, version, name, checksum, all_sql, "failed", has_destructive; conn=conn)
          catch record_err
            @error "Failed to record migration failure in history table" exception=record_err
          end
          @error "Error applying migrations" exception=e
        end
        rethrow(e)
      end
    finally
      # renew=true (#276): this handle has FK enforcement OFF and must never go back to the pool as
      # it stands. Renewal re-runs the connect path, which sets the pragma back ON by construction;
      # the suspended handle is closed, so it cannot reach another borrower. A `PRAGMA foreign_keys
      # = ON` here would be unsound — it is silently ignored if a transaction is still open.
      #
      # `rollback_error` is now redundant here (renew=true already short-circuits the helper's
      # classification) — kept deliberately so this call still reads the same as its PG twin and the
      # delete lifecycle, and stays correct if renew ever becomes conditional.
      finalize_transaction_connection!(connection, conn; rollback_error=rollback_error, renew=true)
    end
  end

  if already !== nothing
    @info(_emsg("\e[32mMigration already applied (checksum match) — skipping re-apply.\e[0m"))
    try
      _archive_migration_files(settings, date_str)
    catch e
      @error "Error archiving already-applied migration files" exception=e
    end
    return MigrationResult(:already_applied, string(already[:version]), 0)
  end

  # Archive files (post-commit, best-effort)
  try
    _archive_migration_files(settings, date_str)
  catch e
    @error "Error archiving migration files (migration was applied successfully)" exception=e
  end
  return MigrationResult(:applied, version, length(ordered_statements))
end

# ==============================================================================
# String-based entry point
# ==============================================================================

function migrate(db::String; config::Dict{String,PormGSettings} = config, kwargs...)::MigrationResult
  settings = config[db]
  migrate(settings.connections, settings; kwargs...)
end

# ==============================================================================
# Repair Operations
# ==============================================================================

"""
    _resolve_mark_checksum(checksum, sql_content) -> String

Resolve the checksum `mark_applied` will record, or throw if the caller gave nothing to base it on.

Guardrail for issue #81: a manually-reconciled migration must carry a *verifiable* checksum. When
the caller supplies `sql_content` we hash it; when they supply an explicit `checksum` we trust it;
when they supply neither we refuse rather than fabricate one, because a made-up digest can never be
verified against the real migration and would silently defeat drift detection. Pure/DB-free so it
can be unit-tested directly.
"""
function _resolve_mark_checksum(checksum::String, sql_content::String)::String
  if isempty(checksum) && isempty(sql_content)
    throw(InvalidMigrationError(
      "mark_applied requires the migration's `sql_content` (preferred — the checksum is then " *
      "computed from, and verifiable against, the real SQL) or an explicit `checksum`. Refusing " *
      "to fabricate one: a made-up checksum can never be verified and silently defeats drift " *
      "detection (issue #81)."))
  end
  return isempty(checksum) ? compute_checksum(sql_content) : checksum
end

"""
    mark_applied(connection, settings, version, name; checksum, sql_content)

Manually mark a migration version as applied in the history table.
Useful for reconciliation after manual intervention or interrupted migrations.

Requires either `sql_content` (preferred) or an explicit `checksum` so the recorded digest is
verifiable — passing neither is refused rather than fabricated (issue #81). Destructiveness is
classified from `sql_content` when provided instead of being hard-coded, so a manually-reconciled
destructive migration is still flagged in history.
"""
function mark_applied(connection::Union{PormGPostgres, PormGSQLite}, settings::PormGSettings,
                      version::String, name::String;
                      checksum::String = "", sql_content::String = "")
  # Validate arguments before touching the DB so a bad call is a pure ArgumentError.
  checksum = _resolve_mark_checksum(checksum, sql_content)
  init_migrations(connection)

  destr = !isempty(sql_content) && is_destructive(sql_content)
  _record_migration(connection, version, name, checksum, sql_content, "applied", destr)
  @info("Marked version $version as applied.")
end

function mark_applied(db::String, version::String, name::String; config::Dict{String,PormGSettings} = config, kwargs...)
  settings = config[db]
  mark_applied(settings.connections, settings, version, name; kwargs...)
end

"""
    _require_recorded_version(connection, version, op)

Throw `InvalidMigrationError` unless the history table holds a record with `version`. The repair
ops that change an EXISTING record call it first (#733): their `UPDATE`/`DELETE` matches zero rows
on a mistyped version, and they used to log success regardless — so the operator believed a record
was reconciled when nothing had changed.
"""
function _require_recorded_version(connection::Union{PormGPostgres, PormGSQLite}, version::String, op::String)
  any(r -> string(r[:version]) == version, _get_applied_migrations(connection)) && return nothing
  throw(InvalidMigrationError(
    "$op: no migration record has version '$version', so nothing was changed. " *
    "`status(db)` lists the recorded versions."))
end

"""
    mark_failed(connection, settings, version)

Update an existing migration record to 'failed' status.
Useful after manual investigation of a partially-applied migration.

Raises `InvalidMigrationError` when no record has `version`, and changes nothing.
"""
function mark_failed(connection::Union{PormGPostgres, PormGSQLite}, settings::PormGSettings,
                     version::String)
  # Before `init_migrations`, so a refused call does not even create the history table.
  _require_recorded_version(connection, version, "mark_failed")
  init_migrations(connection)
  _update_migration_status(connection, version, "failed")
  @info("Marked version $version as failed.")
end

function mark_failed(db::String, version::String; config::Dict{String,PormGSettings} = config)
  settings = config[db]
  mark_failed(settings.connections, settings, version)
end

"""
    remove_migration_record(connection, settings, version)

Remove a migration record from the history table entirely.
Use with caution — this erases history. Intended for cleanup after
manual rollbacks or test scenarios.

Raises `InvalidMigrationError` when no record has `version`, and changes nothing.
"""
function remove_migration_record(connection::Union{PormGPostgres, PormGSQLite}, settings::PormGSettings,
                                 version::String)
  # Before `init_migrations`, so a refused call does not even create the history table.
  _require_recorded_version(connection, version, "remove_migration_record")
  init_migrations(connection)

  # Bound, never interpolated (#846). No `conn`: `fetch` acquires and releases its own.
  fetch(connection, Dialect.delete_migration_record_sql(connection); params = Any[version])
  @info("Removed migration record for version $version.")
end

function remove_migration_record(db::String, version::String; config::Dict{String,PormGSettings} = config)
  settings = config[db]
  remove_migration_record(settings.connections, settings, version)
end

"""
    discard_pending_migration(settings; backup=true) -> NamedTuple | Nothing
    discard_pending_migration(db::String; config=config, backup=true) -> NamedTuple | Nothing

Discard the un-applied pending migration draft (`migrations/pending_migrations.jl`) for this
connection — e.g. a `makemigrations` plan you generated and then regretted.

A pending migration is only a file with no database state behind it, so this is
filesystem-only: it never touches the `pormg_migrations` history table or the schema (unlike
`mark_applied` / `remove_migration_record`, which mutate applied state). That makes discarding
a draft the one inherently safe, reversible migration op.

When `backup=true` (default) the file is renamed to `pending_migrations.jl.discarded`
(overwriting any previous discard) so the draft can be recovered; otherwise it is deleted.
`makemigrations` overwrites the pending file anyway, so a later regenerate is unaffected — except
for a plan holding hand-written `Data (pre):` / `Data (post):` steps, which `makemigrations` refuses
to overwrite (#740). Discarding is how you throw such a plan away on purpose.

Returns `(discarded=true, path, backup, tables, statements)` describing what was thrown away,
or `nothing` when there is no pending migration. Pairs with [`status`](@ref), which reports
whether a pending file exists.
"""
function discard_pending_migration(settings::PormGSettings; backup::Bool = true)
  Configuration._require_folder_backed(settings, "discard_pending_migration")
  pending_path = joinpath(settings.db_def_folder, "migrations", "pending_migrations.jl")
  if !isfile(pending_path)
    @info(_emsg("\e[32mNo pending migration to discard.\e[0m"))
    return nothing
  end

  # Best-effort summary of what we're discarding. Never let a parse error block the discard —
  # getting rid of a bad/unwanted draft is exactly the point of this function.
  tables = 0
  statements = 0
  try
    plan = _load_migration_plan(settings)
    tables = length(plan)
    statements = sum(length(d) for d in plan; init = 0)
  catch
    # leave counts at 0; the file is still discarded below
  end

  backup_path = nothing
  if backup
    backup_path = pending_path * ".discarded"
    mv(pending_path, backup_path; force = true)
  else
    rm(pending_path)
  end

  @info(_emsg("\e[33mDiscarded pending migration ($(tables) table(s), $(statements) statement(s)).\e[0m" *
        (backup ? " Backup saved to $(backup_path)." : "")))
  return (discarded = true, path = pending_path, backup = backup_path, tables = tables, statements = statements)
end

function discard_pending_migration(db::String; config::Dict{String,PormGSettings} = config, backup::Bool = true)
  settings = config[db]
  discard_pending_migration(settings; backup = backup)
end


# ==============================================================================
# Data steps (#740): `run_once`
# ==============================================================================

"""
    run_once(f, db::String, name; transaction = true, lock_wait = 30, config) -> Symbol
    run_once(f, connection, settings, name; transaction = true, lock_wait = 30) -> Symbol

Run the data step `f` once per database, recorded by `name` (#740). `f` receives the database's
pool, so raw SQL inside the step is `fetch(conn, sql)`; ORM calls inside it join the step's
transaction on their own.

```julia
PormG.Migrations.run_once("db", "2026-10-02_backfill_driver_code") do conn
    for d in M.Driver.objects.filter("code__@isnull" => true).list()
        M.Driver.objects.filter("driverid" => d[:driverid]).
            update("code" => uppercase(first(d[:surname], 3)))
    end
end
```

Returns `:applied` when this call ran the step, `:already_applied` when a step of that name is
recorded already (`f` is not called), and `:disabled` on a `change_db: false` connection, where
nothing is read or written — the same contract as [`migrate`](@ref), which a boot script calls
beside it.

- **Recorded in `pormg_migrations_data`**, one row per name, created on first use. The row is the
  whole of "applied": a step is never re-run, whatever its code says now, so give a changed step a
  new name. There is no down step.
- **The migration lock.** On PostgreSQL it holds the advisory lock `migrate` holds
  (`pormg::migrations`), waiting up to `lock_wait` seconds (`OperationalError` naming the holder
  after that), so a data step and a schema migration never run at once and two instances cannot both
  run one step. SQLite has no such lock; there the transactional step checks its record inside its
  `BEGIN IMMEDIATE` transaction, which no other process can share.
- **`transaction = true`** (default): the step and its record commit together. If `f` throws, both
  roll back, nothing is recorded, the error propagates, and the next call runs the step again.
- **`transaction = false`**: for what cannot run inside a transaction — PostgreSQL's
  `CREATE INDEX CONCURRENTLY` — or a backfill too large for one. The record is written after `f`
  returns, so a throw records nothing and keeps whatever `f` already did: write such a step to be
  safe to run again (`CREATE INDEX CONCURRENTLY IF NOT EXISTS`). On SQLite nothing serializes it:
  two runners can both run `f`, and the one that records second returns `:already_applied`. An
  index a step creates must also be declared on the model (`db_index = true`),
  or the next `makemigrations` plans to drop it.

Raises `TransactionError` when called inside an open transaction on the same database — a step's
commit has to be its own — and `InvalidValueError` for an empty name or one longer than 255
characters. It reads no files, so a `register_connection` database works too.

Expand → backfill → contract is two plans with a `run_once` between them: see *Data Migrations* in
the advanced migrations guide.
"""
function run_once(f::Function, connection::Union{PormGPostgres, PormGSQLite}, settings::PormGSettings,
                  name::AbstractString; transaction::Bool = true, lock_wait::Real = 30)::Symbol
  step = String(name)
  isempty(strip(step)) && throw(InvalidValueError("run_once needs a step name; got $(repr(step))."))
  length(step) <= 255 || throw(InvalidValueError(
    "run_once step names are at most 255 characters (pormg_migrations_data.name); got $(length(step))."))
  # Validated before the change_db return, as `migrate` does: a bad value fails on every instance.
  timeouts = _migration_timeouts(lock_wait)
  if !settings.change_db
    @warn("The database is not set to change_db, so the data step $(repr(step)) was not run.")
    return :disabled
  end
  # The `atomic(durable = true)` rule: inside an enclosing transaction the step's "commit" would be a
  # savepoint, recorded as applied while the outer block can still roll it back.
  Configuration.in_transaction_on(connection) && throw(TransactionError(
    "run_once($(repr(step))) cannot run inside an open transaction on this database: a data step " *
    "commits on its own, together with its record. Call it outside the transaction block."))
  return _run_once_locked(f, connection, settings, step, transaction, timeouts)
end

function run_once(f::Function, db::String, name::AbstractString; config::Dict{String,PormGSettings} = config,
                  transaction::Bool = true, lock_wait::Real = 30)::Symbol
  settings = config[db]
  return run_once(f, settings.connections, settings, name; transaction = transaction, lock_wait = lock_wait)
end

# PostgreSQL: everything under the migration lock — the table, the record check, the step.
function _run_once_locked(f::Function, connection::PormGPostgres, settings::PormGSettings, step::String,
                          transaction::Bool, timeouts::_MigrationTimeouts)::Symbol
  return AdvisoryLock.with_advisory_lock(connection, _migration_lock_key(settings);
                                         wait = true, timeout_ms = timeouts.lock_wait_ms) do
    fetch(connection, Dialect.create_data_steps_table(connection))
    # Under the lock, so no other run_once or migrate can record this step in between.
    _data_step_recorded(connection, step) && return :already_applied
    if transaction
      run_in_transaction(connection) do
        f(connection)
        _record_data_step(connection, step, true)   # inside the context: commits with the step
      end
    else
      f(connection)
      _record_data_step(connection, step, false)
    end
    return :applied
  end
end

# SQLite: no advisory lock. The transactional step checks its record INSIDE `BEGIN IMMEDIATE` (the
# #737 shape), so two processes cannot both pass the check. The non-transactional one is not
# serialized at all, on purpose: holding the process-wide SQLite write lock across `f` — a backfill
# too large for one transaction, maybe spawning writer tasks of its own — would stall every other
# writer in the process, and deadlock on a task `f` waits for. Two runners can therefore both run
# it (which the docs tell its author to allow for); the second to record hits the UNIQUE name and
# reports `:already_applied`.
function _run_once_locked(f::Function, connection::PormGSQLite, settings::PormGSettings, step::String,
                          transaction::Bool, ::_MigrationTimeouts)::Symbol
  fetch(connection, Dialect.create_data_steps_table(connection))
  if transaction
    ran = run_in_transaction(connection) do
      _data_step_recorded(connection, step) && return false
      f(connection)
      _record_data_step(connection, step, true)
      return true
    end
    return ran ? :applied : :already_applied
  end
  _data_step_recorded(connection, step) && return :already_applied
  f(connection)
  try
    _record_data_step(connection, step, false)
  catch e
    # Another runner recorded the same name while `f` ran here.
    (e isa IntegrityError && _data_step_recorded(connection, step)) || rethrow()
    return :already_applied
  end
  return :applied
end

# `fetch` with no `conn`, so inside `run_in_transaction` both run on the transaction's connection:
# an explicit `conn` would hand it back to the pool mid-transaction (#139).
_data_step_recorded(connection::Union{PormGPostgres, PormGSQLite}, step::String)::Bool =
  nrow(DataFrame(fetch(connection, Dialect.select_data_step_sql(connection); params = Any[step]))) > 0

_record_data_step(connection::Union{PormGPostgres, PormGSQLite}, step::String, transactional::Bool) =
  fetch(connection, Dialect.insert_data_step_sql(connection); params = Any[step, transactional])

# The recorded data steps for `status()`: empty when the table does not exist yet, which `status`
# reports rather than creates — it is read-only.
function _data_steps(connection::Union{PormGPostgres, PormGSQLite})::Vector{NamedTuple}
  exists = DataFrame(fetch(connection, Dialect.data_steps_table_exists_sql(connection)))[1, 1]
  (exists === true || (exists isa Integer && exists > 0)) || return NamedTuple[]
  rows = DataFrame(fetch(connection, Dialect.select_all_data_steps_sql(connection)))
  # `transactional` as a Bool on both engines: SQLite stores the BOOLEAN as 0/1.
  return NamedTuple[(name = String(r.name), transactional = Bool(r.transactional), applied_at = r.applied_at)
                    for r in eachrow(rows)]
end
