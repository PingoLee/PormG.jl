using Test
using PormG
using PormG.Models
using PormG.Migrations
using OrderedCollections
import PormG: PormGModel, PormGPostgres, PormGSQLite

# Mock connection types for dispatch — subtype abstract PormG types
struct MockPostgres <: PormGPostgres end
struct MockSQLite <: PormGSQLite end

@testset "Migration Planner Logic" begin
    
    mock_conn_pg = MockPostgres()
    mock_conn_sl = MockSQLite()
    
    settings = PormG.Configuration.Settings()
    settings.change_db = true

    @testset "New Table Detection (Postgres)" begin
        old_models = PormGModel[]
        new_table = Models.Model("test_table",
            id = Models.IDField(primary_key=true),
            name = Models.CharField(max_length=100)
        )
        current_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
            :test_table => Dict{Symbol, Union{Bool, PormGModel}}(:model => new_table, :exist => false)
        )

        plan = Migrations.get_migration_plan(old_models, current_schema, mock_conn_pg, settings)

        @test haskey(plan, :test_table)
        @test any(info -> occursin("CREATE TABLE", info), values(plan[:test_table]))
    end

    @testset "New Table Detection (SQLite)" begin
        old_models = PormGModel[]
        new_table = Models.Model("sqlite_table",
            id = Models.IDField(primary_key=true),
            name = Models.CharField(max_length=100)
        )
        current_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
            :sqlite_table => Dict{Symbol, Union{Bool, PormGModel}}(:model => new_table, :exist => false)
        )

        plan = Migrations.get_migration_plan(old_models, current_schema, mock_conn_sl, settings)

        @test haskey(plan, :sqlite_table)
        @test any(info -> occursin("CREATE TABLE", info), values(plan[:sqlite_table]))
        # SQLite should include AUTOINCREMENT for IDField
        @test any(info -> occursin("AUTOINCREMENT", info), values(plan[:sqlite_table]))
    end

    @testset "Add Field Detection (Postgres)" begin
        old_table = Models.Model("test_table",
            id = Models.IDField(primary_key=true)
        )
        old_models = PormGModel[old_table]

        new_table = Models.Model("test_table",
            id = Models.IDField(primary_key=true),
            new_field = Models.CharField(max_length=200, null=true)
        )
        current_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
            :test_table => Dict{Symbol, Union{Bool, PormGModel}}(:model => new_table, :exist => false)
        )

        plan = Migrations.get_migration_plan(old_models, current_schema, mock_conn_pg, settings)

        @test haskey(plan, :test_table)
        @test any(info -> occursin("ALTER TABLE", info) && occursin("ADD COLUMN", info) && occursin("new_field", info), values(plan[:test_table]))
    end

    @testset "Add Field Detection (SQLite)" begin
        old_table = Models.Model("test_table",
            id = Models.IDField(primary_key=true)
        )
        old_models = PormGModel[old_table]

        new_table = Models.Model("test_table",
            id = Models.IDField(primary_key=true),
            new_field = Models.CharField(max_length=200, null=true)
        )
        current_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
            :test_table => Dict{Symbol, Union{Bool, PormGModel}}(:model => new_table, :exist => false)
        )

        plan = Migrations.get_migration_plan(old_models, current_schema, mock_conn_sl, settings)

        @test haskey(plan, :test_table)
        @test any(info -> occursin("ALTER TABLE", info) && occursin("ADD COLUMN", info) && occursin("new_field", info), values(plan[:test_table]))
    end

    # ==============================================================================
    # Planner Output → Runner Integration: ordering and checksum
    #
    # When the planner generates an OrderedDict-based migration plan,
    # the runner's _order_statements must correctly classify each entry.
    # These tests bridge planner output format and runner consumption.
    # ==============================================================================

    @testset "Planner Output to Runner Ordering" begin
        old_models = PormGModel[]

        # Create a multi-table schema to trigger both CREATE TABLE and constraint entries
        table_a = Models.Model("drivers",
            id = Models.IDField(primary_key=true),
            forename = Models.CharField(max_length=100),
            surname = Models.CharField(max_length=100)
        )
        table_b = Models.Model("results",
            id = Models.IDField(primary_key=true),
            points = Models.IntegerField(null=true)
        )
        current_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}(
            :drivers => Dict{Symbol, Union{Bool, PormGModel}}(:model => table_a, :exist => false),
            :results => Dict{Symbol, Union{Bool, PormGModel}}(:model => table_b, :exist => false)
        )

        plan = Migrations.get_migration_plan(old_models, current_schema, MockPostgres(), settings)

        # Convert plan to the format the runner expects (Vector of OrderedDicts)
        plan_as_dicts = [plan[k] for k in keys(plan)]

        # Runner's _order_statements should split them correctly
        ordered, all_sql = Migrations._order_statements(plan_as_dicts)

        # All CREATE TABLE statements should come first
        # Find the index where non-CREATE statements start
        create_indices = findall(s -> occursin("CREATE TABLE", s), ordered)
        non_create_indices = findall(s -> !occursin("CREATE TABLE", s) && !occursin("CREATE INDEX", s), ordered)

        if !isempty(create_indices) && !isempty(non_create_indices)
            @test maximum(create_indices) < minimum(non_create_indices)
        end

        # Checksum of the ordered SQL should be deterministic
        checksum1 = Migrations.compute_checksum(all_sql)
        checksum2 = Migrations.compute_checksum(all_sql)
        @test checksum1 == checksum2
    end

    @testset "Drop Table Detection (Postgres)" begin
        # When a model exists in the database but not in current code,
        # the planner should generate a DROP TABLE instruction.
        old_table = Models.Model("obsolete_table",
            id = Models.IDField(primary_key=true),
            name = Models.CharField(max_length=100)
        )
        old_models = PormGModel[old_table]

        # Empty current_schema means the table should be dropped
        current_schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormGModel}}}()

        plan = Migrations.get_migration_plan(old_models, current_schema, MockPostgres(), settings, interactive=false)

        @test haskey(plan, :obsolete_table)
        @test any(info -> occursin("DROP TABLE", info), values(plan[:obsolete_table]))

        # Verify destructive detection catches this
        plan_dicts = [plan[k] for k in keys(plan)]
        ordered, _ = Migrations._order_statements(plan_dicts)
        destructive = Migrations.detect_destructive_actions(ordered)
        @test !isempty(destructive)
    end

end
