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

    # Table name = model.name lowercased, VERBATIM — no pluralization, no Inflector. Using "Driver"
    # checks the lowercasing; asserting the absence of "drivers" checks no pluralization.
    @testset "Table name is the lowercased model name" begin
        ddl = PormG.Dialect.create_table(MockSLConv(), Models.Model("Driver", driverid = Models.IDField()))
        @test occursin("CREATE TABLE IF NOT EXISTS driver (", ddl)
        @test !occursin("drivers", ddl)
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
