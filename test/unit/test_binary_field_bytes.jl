# ─────────────────────────────────────────────────────────────────────────────
# BinaryField: real BYTEA/BLOB storage, byte-bounded max_length, byte defaults (#296)
# Covers the SQL shape on both backends (column type, byte-length CHECK, DEFAULT byte
# literal), the ALTER path that migrates an existing TEXT column, the SQLite table
# rebuild, and the introspection round-trip that keeps makemigrations from proposing
# the same change forever. Pure SQL-shape tests — no live DB — following the pattern
# of test_positive_small_integer_check.jl.
# ─────────────────────────────────────────────────────────────────────────────

using Test
using PormG
using PormG.Models

# Mock connections for DB-free SQL generation.
struct MockPGBin <: PormG.PormGPostgres end
struct MockSLBin <: PormG.PormGSQLite end

# A Postgres mock whose byte-length-CHECK introspection returns a known name, so the
# DROP-on-change path can be exercised without a database.
struct MockPGBinNamed <: PormG.PormGPostgres end
PormG.get_constraints_byte_length_check(::MockPGBinNamed, table_name::String, field_name::String) = "technical_document_payload_check"

@testset "BinaryField byte storage (#296)" begin

  # ───────────────────────────────────────────────────────────────────────────
  # Constructor: the value contract
  # `default` takes bytes only. A String is rejected even though the WRITE path accepts
  # one, because at model-definition time `default = "0102"` is ambiguous between the
  # four characters and the two bytes they spell.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "constructor accepts bytes and rejects ambiguous defaults" begin
    @test Models.BinaryField().default === nothing
    @test Models.BinaryField().max_length === nothing
    @test Models.BinaryField().type == "BLOB"

    @test Models.BinaryField(default = UInt8[0x01, 0x02]).default == UInt8[0x01, 0x02]
    # Other byte-vector spellings normalize to a plain Vector{UInt8}.
    normalized = Models.BinaryField(default = codeunits("ab")).default
    @test normalized isa Vector{UInt8}
    @test normalized == UInt8[0x61, 0x62]

    @test_throws PormG.FieldValidationError Models.BinaryField(default = "QUJD")
    @test_throws PormG.FieldValidationError Models.BinaryField(default = 42)
    @test_throws PormG.FieldValidationError Models.BinaryField(default = 1.5)

    # The String message must name both decodings, or the user cannot act on it.
    msg = try
      Models.BinaryField(default = "QUJD"); ""
    catch e
      sprint(showerror, e)
    end
    @test occursin("Vector{UInt8}", msg)
    @test occursin("codeunits", msg)
    @test occursin("base64decode", msg)

    # max_length stays a positive integer or nothing.
    @test Models.BinaryField(max_length = 4).max_length == 4
    @test_throws PormG.FieldValidationError Models.BinaryField(max_length = 0)
    @test_throws PormG.FieldValidationError Models.BinaryField(max_length = -1)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # CREATE TABLE: the column type each backend actually needs
  # Before this fix `_get_column_type` had no sBinaryField branch, so both backends fell
  # through to `else return "TEXT"` and every binary column was silently text.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "renders BYTEA on PostgreSQL and BLOB on SQLite" begin
    field = Models.BinaryField()

    pg_col = PormG.Dialect.field_to_column("payload", field, MockPGBin())
    sl_col = PormG.Dialect.field_to_column("payload", field, MockSLBin())

    @test occursin("\"payload\" bytea", pg_col)
    @test occursin("\"payload\" BLOB", sl_col)
    # The regression this guards: neither may render as TEXT again.
    @test !occursin("TEXT", pg_col)
    @test !occursin("TEXT", sl_col)

    # Neither type takes a length parameter, so no `(n)` suffix may appear even when the
    # field is bounded — `bytea(4)` is not valid SQL.
    bounded = Models.BinaryField(max_length = 4)
    @test occursin("\"payload\" bytea ", PormG.Dialect.field_to_column("payload", bounded, MockPGBin()))
    @test occursin("\"payload\" BLOB ", PormG.Dialect.field_to_column("payload", bounded, MockSLBin()))
    @test !occursin("bytea(", PormG.Dialect.field_to_column("payload", bounded, MockPGBin()))
    @test !occursin("BLOB(", PormG.Dialect.field_to_column("payload", bounded, MockSLBin()))
  end

  # ───────────────────────────────────────────────────────────────────────────
  # max_length reaches the DDL as a BYTE-length CHECK
  # The function diverges: PostgreSQL has octet_length; SQLite has no octet_length, and
  # its length() already returns bytes for a BLOB.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "max_length emits a byte-length CHECK on both backends" begin
    bounded = Models.BinaryField(max_length = 1024)

    pg_col = PormG.Dialect.field_to_column("payload", bounded, MockPGBin())
    sl_col = PormG.Dialect.field_to_column("payload", bounded, MockSLBin())

    @test occursin("CHECK (octet_length(\"payload\") <= 1024)", pg_col)
    @test occursin("CHECK (length(\"payload\") <= 1024)", sl_col)

    # Unbounded (the default) emits no CHECK at all, rather than comparing against nothing.
    unbounded = Models.BinaryField()
    @test !occursin("CHECK", PormG.Dialect.field_to_column("payload", unbounded, MockPGBin()))
    @test !occursin("CHECK", PormG.Dialect.field_to_column("payload", unbounded, MockSLBin()))
  end

  # ───────────────────────────────────────────────────────────────────────────
  # default= renders as a backend-specific byte literal
  # `_format_default_sql_value`'s generic fallthrough is `string(value)`, which would have
  # emitted the Julia repr `UInt8[0x01, 0x02]` as literal SQL text.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "default renders as a byte literal, not a Julia repr" begin
    field = Models.BinaryField(default = UInt8[0x01, 0x02])

    pg_col = PormG.Dialect.field_to_column("payload", field, MockPGBin())
    sl_col = PormG.Dialect.field_to_column("payload", field, MockSLBin())

    @test occursin("DEFAULT '\\x0102'::bytea", pg_col)
    @test occursin("DEFAULT X'0102'", sl_col)
    @test !occursin("UInt8", pg_col)
    @test !occursin("UInt8", sl_col)

    # High bytes keep their two-digit hex form (0x0f must not render as "f").
    high = Models.BinaryField(default = UInt8[0x0F, 0xFF])
    @test occursin("DEFAULT '\\x0fff'::bytea", PormG.Dialect.field_to_column("p", high, MockPGBin()))
    @test occursin("DEFAULT X'0fff'", PormG.Dialect.field_to_column("p", high, MockSLBin()))
  end

  # ───────────────────────────────────────────────────────────────────────────
  # ALTER: migrating an existing TEXT column
  # PostgreSQL has no assignment cast to bytea, so a bare `ALTER ... TYPE bytea` fails
  # with "column cannot be cast automatically". Every app that used BinaryField before
  # this change has a text column, so this is the normal upgrade path.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "PostgreSQL ALTER carries a USING cast" begin
    sql = PormG.Dialect.alter_field(MockPGBin(), "technical_document", "payload",
                                    Models.BinaryField(), Models.TextField(), Symbol[:type])

    @test occursin("TYPE bytea", sql)
    @test occursin("USING convert_to(\"payload\", 'UTF8')", sql)
    # USING must follow the type, not precede it.
    @test findfirst("TYPE bytea", sql).start < findfirst("USING", sql).start
  end

  # ───────────────────────────────────────────────────────────────────────────
  # ALTER: the byte-length CHECK tracks model state
  # Unlike the non-negative CHECK, this clause embeds its bound — so it must also be
  # replaced when max_length merely CHANGES, with no type transition at all.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "byte CHECK is added, replaced and dropped as max_length changes" begin
    # Added alongside a type change, after the TYPE statement.
    added = PormG.Dialect.alter_field(MockPGBin(), "technical_document", "payload",
                                      Models.BinaryField(max_length = 4), Models.TextField(),
                                      Symbol[:type, :max_length])
    @test occursin("ADD CHECK (octet_length(\"payload\") <= 4)", added)
    @test findfirst("TYPE bytea", added).start < findfirst("ADD CHECK", added).start

    # Changed 4 -> 8 with no type change: drop the stale clause, add the new one.
    changed = PormG.Dialect.alter_field(MockPGBinNamed(), "technical_document", "payload",
                                        Models.BinaryField(max_length = 8),
                                        Models.BinaryField(max_length = 4), Symbol[:max_length])
    @test occursin("DROP CONSTRAINT \"technical_document_payload_check\"", changed)
    @test occursin("ADD CHECK (octet_length(\"payload\") <= 8)", changed)
    @test findfirst("DROP CONSTRAINT", changed).start < findfirst("ADD CHECK", changed).start
    # A max_length-only change must NOT rewrite the column type — that would rebuild the
    # whole table for nothing.
    @test !occursin("TYPE bytea", changed)

    # Removed: drop only.
    removed = PormG.Dialect.alter_field(MockPGBinNamed(), "technical_document", "payload",
                                        Models.BinaryField(), Models.BinaryField(max_length = 4),
                                        Symbol[:max_length])
    @test occursin("DROP CONSTRAINT \"technical_document_payload_check\"", removed)
    @test !occursin("ADD CHECK", removed)

    # Unchanged bound: no constraint churn at all.
    unchanged = PormG.Dialect.alter_field(MockPGBinNamed(), "technical_document", "payload",
                                          Models.BinaryField(max_length = 4),
                                          Models.BinaryField(max_length = 4), Symbol[:null])
    @test !occursin("CHECK", unchanged)

    # Transitioning AWAY from a bounded BinaryField must drop the stale byte CHECK, and drop it
    # BEFORE the type change — an `octet_length` clause left in place would block the cast.
    away = PormG.Dialect.alter_field(MockPGBinNamed(), "technical_document", "payload",
                                     Models.TextField(), Models.BinaryField(max_length = 4),
                                     Symbol[:type])
    @test occursin("DROP CONSTRAINT \"technical_document_payload_check\"", away)
    @test occursin("TYPE text", away)
    @test findfirst("DROP CONSTRAINT", away).start < findfirst("TYPE text", away).start
    @test !occursin("ADD CHECK", away)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # SQLite rebuild casts legacy TEXT rows into blobs
  # A BLOB-declared column has BLOB affinity, i.e. NO affinity — SQLite converts nothing
  # on insert. Without the CAST the rebuilt table holds TEXT-class rows alongside new
  # BLOB-class ones, and SQLite.jl types the whole column from the first row.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "SQLite table rebuild casts the column to BLOB" begin
    model = Models.Model("technical_document";
                         id = Models.IDField(),
                         payload = Models.BinaryField(),
                         name = Models.CharField(max_length = 50))

    sql = PormG.Dialect.alter_field(MockSLBin(), model, "payload",
                                    Models.BinaryField(), Models.TextField(), Symbol[:type])

    @test occursin("CAST(\"payload\" AS BLOB)", sql)
    # Non-binary columns are copied verbatim — the cast is not applied indiscriminately.
    @test occursin("\"name\"", sql)
    @test !occursin("CAST(\"name\"", sql)

    # INSERT targets and SELECT expressions must stay the same length, or the positional
    # copy writes values into the wrong columns.
    insert_line = only(filter(l -> occursin("INSERT INTO", l), split(sql, "\n")))
    target_list = match(r"INSERT INTO \"[^\"]+\" \((.*?)\) SELECT (.*?) FROM", insert_line)
    @test target_list !== nothing
    @test length(split(target_list.captures[1], ", ")) == length(split(target_list.captures[2], ", "))
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Introspection round-trip — the phantom-drift guard
  # `makemigrations` diffs the live schema against the models file, and `max_length` is
  # part of the field state it compares. If introspection cannot recover the bound and the
  # default, every run proposes the same ALTER forever — and on SQLite that means
  # rebuilding the whole table each time.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "SQLite DDL round-trips back to an equivalent BinaryField" begin
    original = Models.BinaryField(default = UInt8[0x01, 0x02], max_length = 4)
    column = PormG.Dialect.field_to_column("payload", original, MockSLBin())

    sql = """CREATE TABLE "technical_document" (
      "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
      $column,
      "name" TEXT NOT NULL
    );"""

    recovered = PormG.Migrations.convertSQLToModel(sql)
    payload = recovered.fields["payload"]

    @test payload isa Models.sBinaryField
    @test payload.default == UInt8[0x01, 0x02]
    @test payload.max_length == 4

    # The CHECK clause must not be mistaken for a column, and the neighbouring column's
    # own type must survive — the DEFAULT capture used to swallow the trailing CHECK.
    @test !haskey(recovered.fields, "length")
    @test recovered.fields["name"] isa Models.sCharField
  end

  @testset "an unbounded, defaultless BLOB column round-trips too" begin
    column = PormG.Dialect.field_to_column("payload", Models.BinaryField(null = true), MockSLBin())
    sql = """CREATE TABLE "technical_document" (\n  "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,\n  $column\n);"""

    payload = PormG.Migrations.convertSQLToModel(sql).fields["payload"]
    @test payload isa Models.sBinaryField
    @test payload.default === nothing
    @test payload.max_length === nothing
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Literal decoders degrade rather than raise
  # Introspection must stay able to read a hand-written or foreign table. A DEFAULT it
  # cannot parse becomes "no default", the same posture Model_to_str takes for a field it
  # cannot render — raising here would abort the whole schema read.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "blob-literal decoders handle malformed input" begin
    @test PormG.Migrations._sqlite_blob_literal_bytes("X'0102'") == UInt8[0x01, 0x02]
    @test PormG.Migrations._sqlite_blob_literal_bytes("x'abcd'") == UInt8[0xAB, 0xCD]
    @test PormG.Migrations._sqlite_blob_literal_bytes("X''") == UInt8[]
    @test PormG.Migrations._sqlite_blob_literal_bytes("'plain text'") === nothing
    @test PormG.Migrations._sqlite_blob_literal_bytes("X'0'") === nothing        # odd nibble count
    @test PormG.Migrations._sqlite_blob_literal_bytes("X'zz'") === nothing       # not hex

    @test PormG.Migrations._pg_bytea_literal_bytes("\\x0102") == UInt8[0x01, 0x02]
    @test PormG.Migrations._pg_bytea_literal_bytes("plain") === nothing
    @test PormG.Migrations._pg_bytea_literal_bytes("\\x0") === nothing

    # A DEFAULT that cannot be decoded yields no default instead of raising, so the
    # constructor's strict byte contract never breaks introspection.
    @test PormG.Migrations._normalize_sqlite_default("'not a blob'", :BinaryField) === nothing
    @test PormG.Migrations._normalize_sqlite_default("X'0102'", :BinaryField) == UInt8[0x01, 0x02]
  end

  # ───────────────────────────────────────────────────────────────────────────
  # bulk_copy streams CSV rather than binding parameters
  # It formats each cell through the field's formatter and hands the result to CSV.write,
  # so a `PormGBytes` would be serialized by `show` as the Julia literal
  # `PormGBytes(UInt8[…])` and land in the column as that text. The COPY statement uses
  # FORMAT CSV, where backslash is not an escape character, so PostgreSQL's hex input
  # syntax survives the CSV layer and `byteain` decodes it — giving bulk_copy the same
  # bytes as bulk_insert. (bulk_copy is PostgreSQL-only, guarded in bulk_copy itself.)
  # ───────────────────────────────────────────────────────────────────────────
  @testset "bulk_copy renders bytes as PostgreSQL hex input syntax" begin
    cell = PormG.QueryBuilder._bulk_copy_cell(Models.format_binary_sql(UInt8[0x89, 0x50, 0x00, 0xFF]))
    @test cell == "\\x895000ff"
    @test cell isa AbstractString
    # Explicitly not the Julia repr that `show` would have produced.
    @test !occursin("PormGBytes", cell)
    @test !occursin("UInt8", cell)

    # Every other value passes through untouched — this helper must not perturb the
    # existing bulk_copy contract for any other field type.
    @test PormG.QueryBuilder._bulk_copy_cell("plain") == "plain"
    @test PormG.QueryBuilder._bulk_copy_cell(42) == 42
    @test PormG.QueryBuilder._bulk_copy_cell(missing) === missing
    @test PormG.QueryBuilder._bulk_copy_cell(nothing) === nothing
  end

  # ───────────────────────────────────────────────────────────────────────────
  # bulk_update casts source columns by field type, and "BLOB" is not a PG type
  # Its CTE renders `SET "col" = source."col"::<type>` from `field.type` lowercased. Every
  # other field's `.type` happens to spell a real PostgreSQL type (varchar, jsonb,
  # timestamptz, decimal, interval) — `BLOB` does not exist in PostgreSQL, so the
  # statement failed outright with `type "blob" does not exist`.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "bulk_update casts a BinaryField source column to bytea" begin
    @test PormG.QueryBuilder._pg_bulk_cast_type(Models.BinaryField()) == "bytea"
    # Never the raw `.type`, which is the SQLite spelling and invalid on PostgreSQL.
    @test PormG.QueryBuilder._pg_bulk_cast_type(Models.BinaryField()) != "blob"

    # Every other field keeps the existing behaviour exactly.
    @test PormG.QueryBuilder._pg_bulk_cast_type(Models.JSONField()) == "jsonb"
    @test PormG.QueryBuilder._pg_bulk_cast_type(Models.DateTimeField()) == "timestamptz"
    @test PormG.QueryBuilder._pg_bulk_cast_type(Models.CharField()) == "varchar"
    @test PormG.QueryBuilder._pg_bulk_cast_type(Models.IntegerField()) == "integer"

    # ImageField/FileField share `.type == "BLOB"` but render as TEXT, so they must NOT be
    # remapped to bytea — keying this on the struct rather than the type string is what keeps
    # them out. (Their own `::blob` cast is a separate pre-existing bug, untouched here.)
    @test PormG.QueryBuilder._pg_bulk_cast_type(Models.ImageField()) == "blob"
    @test PormG.QueryBuilder._pg_bulk_cast_type(Models.FileField()) == "blob"
  end

  # ───────────────────────────────────────────────────────────────────────────
  # The column regex is shared by EVERY field type, not just binary
  # #296 had to narrow its DEFAULT branch so a trailing `CHECK (...)` on a binary column
  # stopped being swallowed into the default. That branch is the one every other field's
  # default also flows through, so these pin the shapes that must keep working — most
  # importantly SQLite's `DEFAULT (expr)` form, which `_strip_sqlite_default_wrapper`
  # exists to unwrap and which a naively-narrowed branch silently drops.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "DEFAULT parsing is unchanged for non-binary columns" begin
    function _default_of(column_sql, field_name)
      sql = """CREATE TABLE "scratch" (\n  "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,\n  $column_sql\n);"""
      return getfield(PormG.Migrations.convertSQLToModel(sql).fields[field_name], :default)
    end

    # Quoted strings, including the empty string.
    @test _default_of("\"note\" TEXT NOT NULL DEFAULT 'hello'", "note") == "hello"
    @test _default_of("\"note\" TEXT NOT NULL DEFAULT ''", "note") == ""
    # Bare tokens.
    @test _default_of("\"laps\" INTEGER NOT NULL DEFAULT 0", "laps") == 0
    @test _default_of("\"flag\" BOOLEAN NOT NULL DEFAULT TRUE", "flag") == true
    # Parenthesized expressions — SQLite's `DEFAULT (expr)` form.
    @test _default_of("\"laps\" INTEGER NOT NULL DEFAULT (0)", "laps") == 0
    @test _default_of("\"note\" TEXT NOT NULL DEFAULT ('hi')", "note") == "hi"
    # No DEFAULT at all stays nothing.
    @test _default_of("\"note\" TEXT NOT NULL", "note") === nothing
  end

  # ───────────────────────────────────────────────────────────────────────────
  # ImageField and FileField must not be swept up
  # They share BinaryField's `type == "BLOB"` string but are `sImageField` and store a
  # filesystem path as text, so anything keyed on the type string would break them.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "ImageField/FileField keep text semantics despite type == BLOB" begin
    for ctor in (Models.ImageField, Models.FileField)
      field = ctor()
      @test field.type == "BLOB"
      @test !(field isa Models.sBinaryField)

      # No byte CHECK and no bytea column — these are unchanged by #296.
      col = PormG.Dialect.field_to_column("photo", field, MockPGBin())
      @test !occursin("octet_length", col)
      @test !occursin("bytea", col)
    end
  end
end
