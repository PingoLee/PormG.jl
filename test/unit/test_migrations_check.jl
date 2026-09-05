# ==============================================================================
# MIGRATIONS: check() — the schema-compatibility report (#475)
#
# `check` answers a question the warnings cannot. `convert_schema_to_models` warns once per column
# as it reads, so the information exists only in the log of a run you have to have already made —
# and before #475 the case that mattered most produced NO warning at all, because a textual column
# silently kept an expression default as a quoted literal.
#
# Hermetic. The PostgreSQL arm is pure over the frame `get_database_schema` returns, so it is driven
# with a synthetic `DataFrame`; the SQLite arm runs against a real temp database, which is the house
# idiom for the live reader (test_introspection_guards.jl).
#
# Helpers are `_chk_`-prefixed on purpose: `test/runtests.jl` includes every unit file into ONE
# module, and `test_introspection_guards.jl` already defines a top-level `_col`.
# ==============================================================================

using Test
using DataFrames
using JSON
using Logging
using PormG

isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
import PormG: PormGSQLite, PormGPostgres
import PormG.ConnectionPool: SQLiteConnectionPool, fetch
import PormG.Migrations: check, SchemaCheckResult, SchemaCheckFinding, convert_schema_to_models

# One entry of the PostgreSQL `columns` JSON aggregate — the same shape the schema query emits and
# `convertSQLToModel(::DataFrameRow)` reads.
_chk_col(name, type; default = nothing, notnull = false) =
  Dict{String, Any}("name" => name, "type" => type, "notnull" => notnull, "default" => default,
                    "identity" => "", "unique" => false,
                    "non_negative_check" => false, "byte_limit" => nothing)

# A multi-row stand-in for `get_database_schema(::PormGPostgres)`; `tables` is table_name => columns.
_chk_schema_frame(tables::Vector{<:Pair}) = DataFrame(
  table_name   = [String(t.first) for t in tables],
  columns      = [JSON.json(t.second) for t in tables],
  primary_keys = [JSON.json(["id"]) for _ in tables],
  foreign_keys = [missing for _ in tables],
  indexes      = [missing for _ in tables],
)

# ─────────────────────────────────────────────────────────────────────────────
# The PostgreSQL arm: an expression default is a finding, every literal is not
# The negative half carries the weight. A check that simply reported every column WITH a default
# would pass the positive assertions and be useless, so each literal form the cleaner recognises is
# pinned as a NON-finding — including the two that reach the same unquoted fallthrough an
# expression does (`5`, `true`), and the quoted literal that is SPELLED like an expression.
# ─────────────────────────────────────────────────────────────────────────────
@testset "check reports expression defaults and nothing else (PostgreSQL) (#475)" begin
  frame = _chk_schema_frame([
    "lap_note" => [_chk_col("id", "bigint"; notnull = true),
                   _chk_col("created_at", "timestamp with time zone"; default = "now()"),
                   _chk_col("note", "text"; default = "concat('a'::text, 'b'::text)"),
                   # Literals — none of these may be reported.
                   _chk_col("ok", "integer"; default = "5"),
                   _chk_col("neg", "integer"; default = "-1"),
                   _chk_col("flag", "boolean"; default = "true"),
                   _chk_col("team", "character varying"; default = "'Ferrari'::character varying"),
                   _chk_col("looks_like", "text"; default = "'now()'::text"),
                   _chk_col("nulled", "text"; default = "NULL::text"),
                   _chk_col("plain", "text")],
  ])

  findings = PormG.Migrations._pg_expression_default_findings(frame; ignore_table = String[])

  @test Set((f.table, only(f.columns)) for f in findings) ==
        Set([("lap_note", "created_at"), ("lap_note", "note")])
  @test all(f.kind === :expression_default for f in findings)

  # The expression text is carried verbatim, which is what makes the report actionable: the user
  # has to find the column in their own DDL.
  by_col = Dict(only(f.columns) => f for f in findings)
  @test by_col["created_at"].detail == "now()"
  @test by_col["note"].detail == "concat('a'::text, 'b'::text)"
end

# ─────────────────────────────────────────────────────────────────────────────
# The ignore list is honoured, so check() reports exactly the tables the importer reads
# A framework table PormG deliberately never imports is not a finding — reporting one would send
# the user hunting for a column no model was ever going to describe. `pormg_migrations.applied_at`
# is the concrete case: PormG's OWN table carries `DEFAULT now()`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "check honours the introspection ignore list (#475)" begin
  frame = _chk_schema_frame([
    "pormg_migrations" => [_chk_col("id", "bigint"), _chk_col("applied_at", "timestamp with time zone"; default = "now()")],
    "django_session"   => [_chk_col("id", "bigint"), _chk_col("expire_date", "timestamp with time zone"; default = "now()")],
    "lap_note"         => [_chk_col("id", "bigint"), _chk_col("created_at", "timestamp with time zone"; default = "now()")],
  ])

  findings = PormG.Migrations._pg_expression_default_findings(
      frame; ignore_table = PormG.postgres_ignore_table)
  @test Set(f.table for f in findings) == Set(["lap_note"])

  # …and the control: with no ignore list, all three are found. Without this the assertion above
  # would also pass on an arm that reported nothing at all.
  @test length(PormG.Migrations._pg_expression_default_findings(frame; ignore_table = String[])) == 3
end

# ─────────────────────────────────────────────────────────────────────────────
# The SQLite arm, live — and the assertion that keeps check() honest
# `check` is an INDEPENDENT read: it does not thread a side channel out of
# `convert_schema_to_models`, it re-reads the schema and classifies it with the same two cleaners.
# What that buys, and what it costs, is spelled out at the assertion itself below — it pins the
# enumeration, the ignore rules and the `type_sym` derivation, which are what the two sides really
# do derive separately; it cannot catch them agreeing on a wrong answer.
# ─────────────────────────────────────────────────────────────────────────────
@testset "check agrees with the importer, column for column (SQLite) (#475)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "chk.sqlite"); pool_size = 1)
    try
      fetch(pool, """CREATE TABLE "lap_note" (
          "id" INTEGER PRIMARY KEY,
          "created_at" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
          "d" DATE DEFAULT CURRENT_DATE,
          "n" INTEGER DEFAULT (abs(random()) % 10),
          "note" TEXT DEFAULT CURRENT_TIMESTAMP,
          "ok" INTEGER DEFAULT 5,
          "team" TEXT DEFAULT 'Ferrari',
          "looks_like" TEXT DEFAULT 'CURRENT_TIMESTAMP',
          "plain" TEXT)""")

      settings = PormG.Configuration.Settings()

      # check() must be SILENT. It builds no field, so it cannot raise `FieldValidationError` and
      # must not re-emit the importer's warnings — a diagnostic that logs what it reports would
      # double every warning in a run that used both.
      result = @test_logs min_level = Logging.Warn check(pool, settings)

      @test result isa SchemaCheckResult
      @test result.backend === :sqlite
      @test !isempty(result)

      reported = Set((f.table, only(f.columns)) for f in result.findings)
      @test reported == Set([("lap_note", "created_at"), ("lap_note", "d"),
                             ("lap_note", "n"), ("lap_note", "note")])

      # The literals are absent — including `looks_like`, a quoted literal whose CONTENT is an
      # expression's spelling, which no classifier working on the cleaner's unquoted output could
      # tell from the real thing.
      @test !any(only(f.columns) in ("ok", "team", "looks_like", "plain") for f in result.findings)

      # THE agreement assertion, and precisely what it does and does not prove. Both passes call
      # the SAME cleaner on the SAME raw strings, so it cannot catch the two agreeing on a WRONG
      # answer — it is not a check on the classifier. What it does pin is everything around the
      # classifier that the two sides derive INDEPENDENTLY: which tables each enumerates, which
      # ignore rules each applies, and the `type_sym` each derives from the declared column type
      # (the only input `_normalize_sqlite_default` branches on, and the one place `check`
      # deliberately does not reuse the reader's code). Those are the drifts that are actually
      # reachable, and the PostgreSQL half of this pairing catches a real one — see the serial-key
      # testset below, where check() and the reader genuinely DO disagree by construction.
      logs, _ = Test.collect_test_logs() do
        convert_schema_to_models(pool; include_table = ["lap_note"])
      end
      warned = Set(("lap_note", string(Dict(l.kwargs)[:column])) for l in logs
                   if l.level == Logging.Warn && occursin("could not be represented", l.message))
      @test warned == reported

      # Ordering is deterministic, so `show` output and these tests do not depend on PRAGMA order.
      @test issorted([(String(f.kind), f.table, only(f.columns)) for f in result.findings])
    finally
      PormG.ConnectionPool.close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A schema PormG can fully express reports nothing
# The mirror image, and the reason `isempty` is part of the public surface: without it a user
# cannot tell "clean" from "check is broken".
# ─────────────────────────────────────────────────────────────────────────────
@testset "check reports nothing for a schema the models can express (#475)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "clean.sqlite"); pool_size = 1)
    try
      fetch(pool, """CREATE TABLE "constructor" (
          "id" INTEGER PRIMARY KEY,
          "name" TEXT DEFAULT 'Ferrari',
          "points" INTEGER DEFAULT 0,
          "active" BOOLEAN DEFAULT 1)""")
      result = check(pool, PormG.Configuration.Settings())
      @test isempty(result)
      @test isempty(result.findings)
      # …and the importer agrees it had nothing to complain about.
      @test_logs min_level = Logging.Warn convert_schema_to_models(pool; include_table = ["constructor"])
    finally
      PormG.ConnectionPool.close_pool!(pool)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# show() renders both states without ANSI on a non-TTY
# `_emsg` is the shared strip helper every other migration result type uses; a raw escape sequence
# in a captured log or a CI transcript is the failure this guards.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SchemaCheckResult renders legibly in both states (#475)" begin
  empty_out = sprint(show, SchemaCheckResult(:postgres, SchemaCheckFinding[]))
  @test occursin("no findings", empty_out)
  @test !occursin("\e[", empty_out)

  populated = SchemaCheckResult(:sqlite, [
    SchemaCheckFinding(:expression_default, "lap_note", ["created_at"], "CURRENT_TIMESTAMP", "msg"),
    SchemaCheckFinding(:expression_default, "lap_note", ["note"], "CURRENT_TIMESTAMP", "msg")])
  out = sprint(show, populated)
  @test occursin("expression_default", out)
  @test occursin("lap_note.created_at", out)
  @test occursin("CURRENT_TIMESTAMP", out)
  @test occursin("2 finding(s)", out)
  @test !occursin("\e[", out)
end

# ─────────────────────────────────────────────────────────────────────────────
# A key that imports as IDField is not a finding — and every OTHER key still is
# Found in review. `nextval('t_id_seq'::regclass)` is an expression, so the classifier tags it —
# but the reader's bare-`IDField` key arm never consults the default at all, so nothing is dropped
# and nothing is warned. Reporting it would put one finding per table at the top of every ordinary
# PostgreSQL schema, and `UPGRADING`'s "remove the matching default from your model" would be a
# no-op for all of them, because `sIDField.default` is `Union{Int64, Nothing}` and cannot hold an
# expression in the first place.
#
# The suppression is keyed on the ARM, not on the spelling `nextval(`. Both halves matter and both
# are pinned below, because a spelling test is wrong in two directions at once: it stays silent
# about a `varchar` or FK key whose expression happens to start with `nextval(` — arms that really
# DO drop the default — and it reports an integer key whose default is any other expression, which
# the `IDField` arm ignores just the same. The mutation that motivated this: replacing the guard
# with a bare `col_name in pk_set` passed the original version of this testset unchanged.
# ─────────────────────────────────────────────────────────────────────────────
@testset "check does not report a key that imports as IDField (#475)" begin
  frame = _chk_schema_frame([
    "lap_note" => [_chk_col("id", "integer"; notnull = true,
                            default = "nextval('lap_note_id_seq'::regclass)"),
                   _chk_col("created_at", "timestamp with time zone"; default = "now()")],
  ])
  findings = PormG.Migrations._pg_expression_default_findings(frame; ignore_table = String[])
  @test Set(only(f.columns) for f in findings) == Set(["created_at"])

  # THE discriminator against "skip every primary key". An integer key whose default is NOT a
  # sequence call still reaches the `IDField` arm, so it is still suppressed…
  nonseq_key = _chk_schema_frame([
    "lap_note" => [_chk_col("id", "integer"; notnull = true,
                            default = "floor((random() * (1000)::double precision))"),
                   _chk_col("created_at", "timestamp with time zone"; default = "now()")],
  ])
  @test Set(only(f.columns) for f in
            PormG.Migrations._pg_expression_default_findings(nonseq_key; ignore_table = String[])) ==
        Set(["created_at"])

  # …while a key that lands on an arm which DOES read the default is reported, even when the
  # expression is spelled `nextval(`. These are the two rows a spelling test got wrong, and the
  # direction that matters: check() must never be silent about a default the importer dropped.
  uuid_key = _chk_schema_frame([
    "lap_note" => [_chk_col("id", "uuid"; notnull = true, default = "gen_random_uuid()")],
  ])
  @test Set(only(f.columns) for f in
            PormG.Migrations._pg_expression_default_findings(uuid_key; ignore_table = String[])) ==
        Set(["id"])

  varchar_key = DataFrame(
    table_name   = ["code_table"],
    columns      = [JSON.json([_chk_col("code", "character varying(20)"; notnull = true,
                                        default = "nextval('code_seq'::regclass)")])],
    primary_keys = [JSON.json(["code"])],
    foreign_keys = [missing], indexes = [missing])
  @test Set(only(f.columns) for f in
            PormG.Migrations._pg_expression_default_findings(varchar_key; ignore_table = String[])) ==
        Set(["code"])

  fk_key = DataFrame(
    table_name   = ["profile"],
    columns      = [JSON.json([_chk_col("driver_id", "bigint"; notnull = true,
                                        default = "nextval('driver_seq'::regclass)")])],
    primary_keys = [JSON.json(["driver_id"])],
    foreign_keys = [JSON.json([Dict{String,Any}("column" => "driver_id", "table" => "driver",
                                                "pk" => "id", "on_delete" => "a")])],
    indexes      = [missing])
  @test Set(only(f.columns) for f in
            PormG.Migrations._pg_expression_default_findings(fk_key; ignore_table = String[])) ==
        Set(["driver_id"])

  # …and the reader agrees, which is the actual contract: it emits NO warning for `id`, so a
  # finding there would be check() inventing work the importer never reported.
  logs, model = Test.collect_test_logs() do
    PormG.Migrations.convertSQLToModel(
      DataFrame(table_name = ["lap_note"],
                columns = [JSON.json([
                  _chk_col("id", "integer"; notnull = true,
                           default = "nextval('lap_note_id_seq'::regclass)"),
                  _chk_col("created_at", "timestamp with time zone"; default = "now()")])],
                primary_keys = [JSON.json(["id"])],
                foreign_keys = [missing], indexes = [missing])[1, :])
  end
  @test model.fields["id"] isa PormG.Models.sIDField
  warned = Set(string(Dict(l.kwargs)[:column]) for l in logs
               if l.level == Logging.Warn && occursin("could not be represented", l.message))
  @test warned == Set(["created_at"])
  @test warned == Set(only(f.columns) for f in findings)

  # NARROW, and this is the control that keeps it narrow: `nextval(...)` on a NON-key column
  # reaches the generic arm, IS dropped by the importer, and so IS still reported.
  nonkey = _chk_schema_frame([
    "lap_note" => [_chk_col("id", "bigint"; notnull = true),
                   _chk_col("counter", "integer"; default = "nextval('other_seq'::regclass)")],
  ])
  @test Set(only(f.columns) for f in
            PormG.Migrations._pg_expression_default_findings(nonkey; ignore_table = String[])) ==
        Set(["counter"])
end

# ─────────────────────────────────────────────────────────────────────────────
# The IDField carve-out applies on SQLite too
# Found in review: the first version of the carve-out was PostgreSQL-only, so
# `INTEGER PRIMARY KEY DEFAULT (abs(random()))` was reported by check() while the reader's `is_pk`
# arm ignored it in silence — the same disagreement, on the other engine. Live, because the arm
# selection depends on `PRAGMA table_info`'s `pk` column and on `PRAGMA foreign_key_list`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "check does not report a SQLite key that imports as IDField (#475)" begin
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "slkey.sqlite"); pool_size = 1)
    try
      fetch(pool, """CREATE TABLE "lap" (
          "id" INTEGER PRIMARY KEY DEFAULT (abs(random())),
          "note" TEXT DEFAULT CURRENT_TIMESTAMP)""")

      # THE discriminators, and the reason this testset is not just the PostgreSQL one restated:
      # mutating the predicate to `return is_pk` — suppress every key — must FAIL here. Each of
      # these three keys lands on an arm that DOES read the default, so each must still be
      # reported. Without them the SQLite carve-out could be arbitrarily broad and stay green,
      # which is exactly the gap review found in the PostgreSQL twin one round earlier.
      fetch(pool, """CREATE TABLE "driver" ("id" INTEGER PRIMARY KEY, "name" TEXT)""")
      # A UUID key — the reader reconstructs `UUIDField` and drops the default through
      # `_field_or_drop_default` (#334).
      fetch(pool, """CREATE TABLE "uuid_key" (
          "id" UUID PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
          "label" TEXT)""")
      # A SIZED textual key — `CharField(primary_key=true, max_length=n)` (#409). A LENGTHLESS one
      # would fall through to `IDField` instead, which is why the `(n)` is what matters.
      fetch(pool, """CREATE TABLE "code_key" (
          "code" TEXT(8) PRIMARY KEY DEFAULT (lower(hex(randomblob(4)))),
          "label" TEXT)""")
      # A key that is ALSO a foreign key — the relation arm, via `_fk_default_or_warn` (#409).
      fetch(pool, """CREATE TABLE "profile" (
          "driver_id" INTEGER PRIMARY KEY REFERENCES "driver"("id") DEFAULT (abs(random())),
          "bio" TEXT)""")

      result = check(pool, PormG.Configuration.Settings())
      reported = Set((f.table, only(f.columns)) for f in result.findings)
      @test reported == Set([("lap", "note"), ("uuid_key", "id"),
                             ("code_key", "code"), ("profile", "driver_id")])
      # The integer key is the ONLY suppression, and it is suppressed on the arm, not the spelling:
      # `(abs(random()))` is not a sequence call.
      @test !any(f.table == "lap" && only(f.columns) == "id" for f in result.findings)

      # …and the importer agrees, column for column, across all five tables. That equality is the
      # contract; the explicit set above is what makes a shared wrong answer visible.
      logs, models = Test.collect_test_logs() do
        convert_schema_to_models(pool)
      end
      by = Dict(lowercase(string(m.name)) => m for m in models)
      @test by["lap"].fields["id"] isa PormG.Models.sIDField
      @test by["uuid_key"].fields["id"] isa PormG.Models.sUUIDField
      @test by["code_key"].fields["code"] isa PormG.Models.sCharField
      @test by["profile"].fields["driver_id"] isa PormG.Models.sOneToOneField
      warned = Set((string(Dict(l.kwargs)[:table]), string(Dict(l.kwargs)[:column])) for l in logs
                   if l.level == Logging.Warn && occursin("could not be represented", l.message))
      @test warned == reported
    finally
      PormG.ConnectionPool.close_pool!(pool)
    end
  end
end
