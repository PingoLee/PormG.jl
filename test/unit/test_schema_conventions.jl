# ==============================================================================
# UNIT TESTS: Schema Conventions Freeze (issue #33)
#
# #33 freezes the conventions PormG uses when it generates a schema from a model: table naming, FK
# column spelling, default on_delete, identifier quoting, and the (no) implicit primary key. The
# freeze is documented in docs/src/schema_conventions.md, but documentation alone does not prevent
# drift — these tests PIN the conventions so an accidental change (e.g. adding Inflector
# pluralization or a Django-style `_id` suffix) fails CI instead of silently diverging from the
# frozen contract.
#
# Pure SQL-shape tests (no live DB): they render DDL via Dialect.create_table / field_to_column with
# mock connections, the same pattern as test_positive_small_integer_check.jl.
# ==============================================================================

using Test
using PormG
using PormG.Models

# DB-free SQL generation against both dialects.
struct MockPGConv <: PormG.PormGPostgres end
struct MockSLConv <: PormG.PormGSQLite end

# Render a model whose single FK carries the given keyword args, for on_delete assertions.
_fk_ddl(; fk_kw...) = PormG.Dialect.create_table(MockSLConv(),
    Models.Model("ratings", id = Models.IDField(), driver = Models.ForeignKey("driver"; fk_kw...)))

@testset "Schema Conventions Freeze (#33)" begin

    # Table name = model.name VERBATIM — no pluralization, no Inflector.
    #
    # This testset used to declare `Model("Driver", …)` to prove the DDL folded the case. Since #300
    # that declaration is rejected outright: a positional name must already be lowercase, because
    # only the DDL folded it while the query builder quoted it as declared, so a mixed-case model
    # migrated one table and queried another. The convention is unchanged — a model name is lowercase
    # in the DDL — but it is now guaranteed at declaration instead of by folding downstream.
    @testset "Table name is the model name, verbatim and unpluralized" begin
        ddl = PormG.Dialect.create_table(MockSLConv(), Models.Model("driver", driverid = Models.IDField()))
        # QUOTED since #59: `create_table` used to write the table identifier bare, which was
        # indistinguishable from this while every table name was lowercase — but an unquoted
        # mixed-case `db_table` would fold to lowercase on PostgreSQL and split the DDL from every
        # (already-quoted) query-side site. The CONVENTION under freeze here is the NAME — verbatim,
        # unpluralized — not the quoting style, which is now uniform with column identifiers.
        @test occursin("CREATE TABLE IF NOT EXISTS \"driver\" (", ddl)
        @test !occursin("drivers", ddl)   # no pluralization, no Inflector
    end

    # The other half of the same convention, post-#300: a name that WOULD have needed folding is a
    # declaration-time error rather than a schema that half-works. Since #59 the escape valve is
    # `db_table`, which carries the physical spelling while the positional name stays logical.
    @testset "A non-lowercase positional name is rejected (#300)" begin
        @test_throws PormG.ModelDefinitionError Models.Model("Driver", driverid = Models.IDField())

        # …and `db_table` is how that intent is expressed instead (#59): one declaration, one table,
        # spelled exactly as given.
        pinned = Models.Model("driver_legacy", db_table = "Driver_Legacy", driverid = Models.IDField())
        @test occursin("CREATE TABLE IF NOT EXISTS \"Driver_Legacy\" (",
                       PormG.Dialect.create_table(MockSLConv(), pinned))
    end

    # FK column = the declared field name, verbatim. PormG never appends `_id` (that is the Django
    # importer's job, not native schema generation).
    @testset "FK column is the field name verbatim (no _id suffix)" begin
        ddl = PormG.Dialect.create_table(MockSLConv(),
            Models.Model("result", resultid = Models.IDField(), driverid = Models.ForeignKey("driver")))
        @test occursin("\"driverid\"", ddl)     # the column equals the field name
        @test !occursin("driverid_id", ddl)     # no Django-style _id suffix
        @test !occursin("\"driver_id\"", ddl)   # not silently transformed
    end

    # Default on_delete is NO ACTION; the documented mapping is frozen (note PROTECT→RESTRICT and
    # DO_NOTHING→NO ACTION). Exercised through the full ForeignKey → create_table path.
    @testset "Default on_delete is NO ACTION; mapping frozen" begin
        @test occursin("ON DELETE NO ACTION", _fk_ddl())                              # default (unset)
        @test occursin("ON DELETE CASCADE",   _fk_ddl(on_delete = "CASCADE"))
        @test occursin("ON DELETE RESTRICT",  _fk_ddl(on_delete = "RESTRICT"))
        @test occursin("ON DELETE RESTRICT",  _fk_ddl(on_delete = "PROTECT"))         # PROTECT → RESTRICT
        @test occursin("ON DELETE SET NULL",  _fk_ddl(on_delete = "SET_NULL", null = true))
        # SET_DEFAULT was the one action missing from this frozen list (#287).
        @test occursin("ON DELETE SET DEFAULT", _fk_ddl(on_delete = "SET_DEFAULT", default = 1))
        @test occursin("ON DELETE NO ACTION", _fk_ddl(on_delete = "DO_NOTHING"))      # DO_NOTHING → NO ACTION
        # And the backend-neutral renderer itself maps an unset on_delete to NO ACTION.
        @test PormG.Dialect._foreign_key_on_delete_sql(nothing) == "NO ACTION"
    end

    # Identifiers are double-quoted on BOTH backends (no backticks, no bare identifiers).
    @testset "Identifiers are double-quoted on both backends" begin
        fk = Models.ForeignKey("driver")
        @test occursin("\"driverid\"", PormG.Dialect.field_to_column("driverid", fk, MockPGConv()))
        @test occursin("\"driverid\"", PormG.Dialect.field_to_column("driverid", fk, MockSLConv()))
    end

    # Native models get NO implicit primary key — you must declare an IDField. (The Django importer
    # auto-adds `id`; native generation does not. That asymmetry is the frozen contract.)
    @testset "No implicit primary key on native models" begin
        plain = PormG.Dialect.create_table(MockSLConv(),
            Models.Model("plain", label = Models.CharField(max_length = 50)))
        @test !occursin("PRIMARY KEY", plain)   # no PK conjured
        @test !occursin("\"id\"", plain)        # no implicit id column

        withpk = PormG.Dialect.create_table(MockSLConv(), Models.Model("withpk", myid = Models.IDField()))
        @test occursin("PRIMARY KEY", withpk)   # an explicit IDField is the only PK source
    end

end
