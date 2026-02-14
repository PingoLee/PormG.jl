using Test
using PormG
using PormG.Models
using PormG.Migrations
using OrderedCollections

using SQLite
using LibPQ

# Mock connection for dispatch
struct MockPostgres <: PormG.PormGPostgres end

@testset "Migration Planner Logic" begin
    
    mock_conn_pg = MockPostgres()
    mock_conn_sl = SQLite.DB(":memory:") # SQLite makes it easy to have a real object without a file
    
    settings = PormG.Configuration.Settings()
    settings.change_db = true

    @testset "New Table Detection (Postgres)" begin
        old_models = PormGModel[]
        new_table = Models.Model("test_table",
            id = Models.IDField(primary_key=true),
            name = Models.CharField(max_length=100)
        )
        current_schema = Dict(
            :test_table => Dict(:model => new_table, :exist => false)
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
        current_schema = Dict(
            :sqlite_table => Dict(:model => new_table, :exist => false)
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
        old_models = [old_table]

        new_table = Models.Model("test_table",
            id = Models.IDField(primary_key=true),
            new_field = Models.CharField(max_length=200, null=true)
        )
        current_schema = Dict(
            :test_table => Dict(:model => new_table, :exist => false)
        )

        plan = Migrations.get_migration_plan(old_models, current_schema, mock_conn_pg, settings)

        @test haskey(plan, :test_table)
        @test any(info -> occursin("ALTER TABLE", info) && occursin("ADD COLUMN", info) && occursin("new_field", info), values(plan[:test_table]))
    end

    @testset "Add Field Detection (SQLite)" begin
        old_table = Models.Model("test_table",
            id = Models.IDField(primary_key=true)
        )
        old_models = [old_table]

        new_table = Models.Model("test_table",
            id = Models.IDField(primary_key=true),
            new_field = Models.CharField(max_length=200, null=true)
        )
        current_schema = Dict(
            :test_table => Dict(:model => new_table, :exist => false)
        )

        plan = Migrations.get_migration_plan(old_models, current_schema, mock_conn_sl, settings)

        @test haskey(plan, :test_table)
        @test any(info -> occursin("ALTER TABLE", info) && occursin("ADD COLUMN", info) && occursin("new_field", info), values(plan[:test_table]))
    end

end
