"""
A keyword a field constructor does not accept is refused (#1333).

`_common_kwargs` used to warn "Unexpected parameter … It will be ignored" and drop the keyword. A
dropped keyword can be a schema the user declared and did not get: `BigIntegerField(primary_key =
true)` loaded, and the table was created with no primary key (`"id" bigint NOT NULL`), so the first
upsert on that key failed at runtime, not where the model was written. The constructor now raises
`FieldValidationError` for every keyword it does not take, a typo included, except the
schema-neutral ones in `Models._SCHEMA_NEUTRAL_FIELD_KWARGS`, which keep the warning.

Rendering is hermetic: `Dialect.field_to_column` dispatches on the abstract backend marker, so a
bare marker struct per engine is a sufficient `conn` (the `test_key_type_round_trip.jl` pattern).
"""
# julia --project=test/integration test/unit/test_field_unaccepted_kwargs.jl

using Test
using PormG
import PormG.Models as FUK_M
import PormG.Migrations

struct FukPg <: PormG.PormGPostgres end
struct FukSl <: PormG.PormGSQLite end
struct FukMy <: PormG.PormGMySQL end

const FUK_ENGINES = (FukPg(), FukSl(), FukMy())

_fuk_err(f) = try
  f(); nothing
catch e
  e
end
_fuk_msg(e) = sprint(showerror, e)
_fuk_ddl(field, conn) = PormG.Dialect.field_to_column("circuitid", field, conn)

@testset "Unaccepted field keywords (#1333)" begin

# What: `primary_key = true` on a field type that cannot carry it raises, naming the spellings that
# work. Expected DDL: none — the model never loads. Why: this is the issue; before, the warning
# scrolled past and the table had no primary key.
@testset "primary_key on a non-key field type raises, naming IDField(generated = false)" begin
  for ctor in (FUK_M.BigIntegerField, FUK_M.IntegerField, FUK_M.PositiveIntegerField,
               FUK_M.TextField, FUK_M.DateField, FUK_M.BooleanField, FUK_M.EmailField)
    e = _fuk_err(() -> ctor(primary_key = true))
    @test e isa FieldValidationError
    msg = _fuk_msg(e)
    @test occursin("does not accept `primary_key`", msg)
    @test occursin("IDField(generated = false)", msg)
    @test occursin("CharField(primary_key = true", msg)
    @test occursin("UUIDField(primary_key = true)", msg)
  end
  # `false` is refused as well: the keyword is not this constructor's, whatever its value.
  @test _fuk_err(() -> FUK_M.BigIntegerField(primary_key = false)) isa FieldValidationError
end

# What: a keyword that changes the schema on another field type is refused where it is not taken.
# Why: each was silently dropped — `TextField(max_length = 30)` stayed a `text` column, a
# `PasswordField(unique = true)` got no UNIQUE, `IDField(db_default = …)` no default and a
# `ManyToManyField(null = true)` nothing.
@testset "a schema keyword on the wrong field type raises" begin
  cases = (
    (() -> FUK_M.TextField(max_length = 30), "TextField", "max_length"),
    (() -> FUK_M.EmailField(max_length = 320), "EmailField", "max_length"),
    (() -> FUK_M.PasswordField(unique = true), "PasswordField", "unique"),
    (() -> FUK_M.PasswordField(db_index = true), "PasswordField", "db_index"),
    (() -> FUK_M.IDField(db_default = "CURRENT_DATE"), "IDField", "db_default"),
    (() -> FUK_M.IntegerField(max_digits = 5), "IntegerField", "max_digits"),
    (() -> FUK_M.CharField(on_delete = "CASCADE"), "CharField", "on_delete"),
    (() -> FUK_M.ManyToManyField("Driver"; null = true), "ManyToManyField", "null"),
    (() -> FUK_M.ManyToManyField("Driver"; db_index = true), "ManyToManyField", "db_index"),
  )
  for (f, ftype, kw) in cases
    e = _fuk_err(f)
    @test e isa FieldValidationError
    msg = _fuk_msg(e)
    @test occursin("$ftype does not accept `$kw`", msg)
    @test occursin("$ftype accepts:", msg)
    # Not a primary-key refusal, so no key advice.
    @test !occursin("IDField(generated = false)", msg)
  end
end

# What: a misspelled keyword raises. Why: nobody can tell that `nul = true` was not meant to make
# the column nullable, so it cannot be warned about as harmless.
@testset "a misspelled keyword raises" begin
  e = _fuk_err(() -> FUK_M.CharField(max_length = 10, nul = true))
  @test e isa FieldValidationError
  @test occursin("CharField does not accept `nul`", _fuk_msg(e))
  @test occursin("correct a misspelling", _fuk_msg(e))
end

# What: several refused keywords are named in ONE message, primary-key advice included. Why: one
# edit fixes the declaration, instead of one edit per re-run.
@testset "every refused keyword is named at once" begin
  e = _fuk_err(() -> FUK_M.BigIntegerField(primary_key = true, max_length = 5, uniqe = true))
  @test e isa FieldValidationError
  msg = _fuk_msg(e)
  @test occursin("`primary_key`, `max_length` and `uniqe`", msg)
  @test occursin("IDField(generated = false)", msg)
  @test occursin("BigIntegerField accepts:", msg)
end

# What: the refusal never shows the value it refused. Why: a `default` can be anything, a secret
# included (#971).
@testset "the refusal does not show the value" begin
  e = _fuk_err(() -> FUK_M.PasswordField(default = "s3cr3t-value"))
  @test e isa FieldValidationError
  @test !occursin("s3cr3t-value", _fuk_msg(e))
end

# What: a schema-neutral keyword on a field that does not take it still warns and is ignored, even
# with a value of the wrong type. Why: it cannot change any column, so refusing it would break
# declarations for nothing (Django's `help_text`, `blank` on a many-to-many).
@testset "schema-neutral keywords keep warn-and-ignore" begin
  f = @test_logs (:warn, r"Unexpected parameter for IntegerField") FUK_M.IntegerField(help_text = "points")
  @test f isa FUK_M.sIntegerField
  @test_logs (:warn, r"Unexpected parameter for TextField") FUK_M.TextField(choices = "not-a-tuple")
  @test_logs (:warn, r"Unexpected parameter for CharField") FUK_M.CharField(auto_now = "not-a-bool")
  @test_logs (:warn, r"Unexpected parameter for ManyToManyField") FUK_M.ManyToManyField("Driver"; blank = true)
  # Ignored means the column is the one the bare constructor renders, on every engine.
  for conn in FUK_ENGINES
    @test _fuk_ddl(f, conn) == _fuk_ddl(FUK_M.IntegerField(), conn)
  end
end

# What: the allowlist holds only attributes no DDL path reads. Why: an entry the column compiler
# reads would make a schema keyword warn-and-ignore again — the #1333 defect behind a list.
@testset "the schema-neutral list is disjoint from the schema attributes" begin
  neutral = Set(FUK_M._SCHEMA_NEUTRAL_FIELD_KWARGS)
  @test isempty(intersect(neutral, Set(Migrations.SCHEMA_ATTRS)))
  # Every entry is a classified non-DB attribute, or one of the two no struct stores.
  @test issubset(neutral, union(Set(Migrations.NON_DB_ATTRS), Set([:help_text, :upload_to])))
  # The non-DB attributes that DO change the database stay out: an index, a join table.
  for k in (:db_index, :through, :db_table, :source_field, :target_field)
    @test !(k in neutral)
  end
end

# What: `_accepted_field_kwargs` is the set the constructor accepts — every keyword it lists builds,
# and the snapshot test's constructors are exactly the table's rows. Why: the Django importer drops
# options by this set, so a set wider than the constructor would let a refused keyword through.
@testset "the accepted set is what the constructor accepts" begin
  @test sort!(String.(collect(keys(FUK_M._FIELD_KWARG_SPECS)))) == sort!([
    "ArrayField", "BigIntegerField", "BinaryField", "BooleanField", "CIDRField", "CharField",
    "DateField", "DateTimeField", "DecimalField", "DurationField", "EmailField", "FileField",
    "FloatField", "ForeignKey", "GenericIPAddressField", "IDField", "ImageField", "IntegerField",
    "JSONField", "OneToOneField", "PasswordField", "PositiveIntegerField",
    "PositiveSmallIntegerField", "SearchVectorField", "SlugField", "TextField", "TimeField",
    "URLField", "UUIDField"])
  @test FUK_M._accepted_field_kwargs("BigIntegerField") ==
        Set([:verbose_name, :unique, :blank, :null, :db_index, :db_column, :default, :db_default, :editable])
  @test :primary_key in FUK_M._accepted_field_kwargs("CharField")
  @test !(:db_default in FUK_M._accepted_field_kwargs("IDField"))
  @test FUK_M._accepted_field_kwargs("ManyToManyField") ==
        Set([:verbose_name, :through, :related_name, :db_table, :source_field, :target_field])
end

# What: the spellings the refusal points at build, with their DDL on all three engines.
# Expected DDL below. Why: the advice must be a declaration that works, and `IDField(generated =
# false)` is a key no engine fills: no identity, a SQLite `BIGINT` key (not a rowid alias), no MySQL
# AUTO_INCREMENT. (Moved by #1393: SQLite and MySQL auto-incremented it, ignoring `generated`.)
@testset "the spellings the refusal names build, with their DDL" begin
  natural = FUK_M.IDField(generated = false)
  @test natural.primary_key && !natural.generated
  @test _fuk_ddl(natural, FukPg()) == "\"circuitid\" bigint PRIMARY KEY UNIQUE NOT NULL"
  @test _fuk_ddl(natural, FukSl()) == "\"circuitid\" BIGINT PRIMARY KEY UNIQUE NOT NULL"
  @test _fuk_ddl(natural, FukMy()) == "`circuitid` BIGINT NOT NULL PRIMARY KEY"

  text_key = FUK_M.CharField(primary_key = true, max_length = 10)
  @test _fuk_ddl(text_key, FukPg()) == "\"circuitid\" varchar(10) PRIMARY KEY NOT NULL"
  @test _fuk_ddl(text_key, FukSl()) == "\"circuitid\" TEXT(10) PRIMARY KEY NOT NULL"
  @test _fuk_ddl(text_key, FukMy()) == "`circuitid` VARCHAR(10) NOT NULL COLLATE utf8mb4_0900_bin PRIMARY KEY"

  uuid_key = FUK_M.UUIDField(primary_key = true)
  @test _fuk_ddl(uuid_key, FukPg()) == "\"circuitid\" uuid PRIMARY KEY NOT NULL"
  @test _fuk_ddl(uuid_key, FukSl()) == "\"circuitid\" TEXT PRIMARY KEY NOT NULL"
  @test _fuk_ddl(uuid_key, FukMy()) == "`circuitid` CHAR(36) NOT NULL COLLATE utf8mb4_0900_bin PRIMARY KEY"

  # And the plain integer column the old warning left behind, for contrast: no PRIMARY KEY.
  @test _fuk_ddl(FUK_M.BigIntegerField(), FukPg()) == "\"circuitid\" bigint NOT NULL"
  @test _fuk_ddl(FUK_M.BigIntegerField(), FukSl()) == "\"circuitid\" INTEGER NOT NULL"
  @test _fuk_ddl(FUK_M.BigIntegerField(), FukMy()) == "`circuitid` BIGINT NOT NULL"
end

# What: a model declaring the refused field fails when it is defined. Why: the failure belongs where
# the model is written, not at the first upsert.
@testset "a model with the refused key fails at definition" begin
  @test _fuk_err(() -> FUK_M.Model("circuit_source";
                                   circuitid = FUK_M.BigIntegerField(primary_key = true),
                                   name = FUK_M.CharField(max_length = 255))) isa FieldValidationError
  m = FUK_M.Model("circuit_source";
                  circuitid = FUK_M.IDField(generated = false),
                  name = FUK_M.CharField(max_length = 255))
  @test m.fields["circuitid"].primary_key
end

end
