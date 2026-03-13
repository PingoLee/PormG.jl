using Test
using PormG
using PormG.Migrations
using SQLite
using DataFrames
using OrderedCollections

# Helper to write models.jl dynamically
function write_test_models(content::String)
    models_path = joinpath(@__DIR__, "db_test_migration", "models.jl")
    open(models_path, "w") do f
        write(f, "module models\nimport PormG.Models\n")
        write(f, content)
        write(f, "\nend")
    end
end

cd(@__DIR__)

@testset "SQLite Migration Integration Tests" begin
    # 1. Setup
    db_name = "db_test_migration"
    db_path = joinpath(@__DIR__, db_name, "migration_test.sqlite")
    
    # Clean up previous runs
    ispath(joinpath(@__DIR__, db_name)) && rm(joinpath(@__DIR__, db_name), recursive=true)
    
    # Use the generator to create the SQLite config
    PormG.Generator.create_db_folder_and_yml(path=joinpath(@__DIR__, db_name), adapter="SQLite")
    
    # Need to update the database path in the generated yml to be absolute or relative to @__DIR__
    yml_path = joinpath(@__DIR__, db_name, "connection.yml")
    yml_content = read(yml_path, String)
    yml_content = replace(yml_content, "database: database.sqlite" => "database: migration_test.sqlite")
    # Also ensure change_db is true (it is by default in my generator change)
    open(yml_path, "w") do f; write(f, yml_content); end

    PormG.Configuration.load(joinpath(@__DIR__, db_name))
    settings = PormG.Configuration.get_settings(joinpath(@__DIR__, db_name))

    @testset "Phase 1: Initial Creation" begin
        write_test_models("""
        MigrationTest = Models.Model(
            id = Models.IDField(),
            name = Models.CharField()
        )
        """)
        
        # Run migrations
        makemigrations(joinpath(@__DIR__, db_name), interactive=false)
        
        # Verify pending_migrations.jl exists
        @test isfile(joinpath(@__DIR__, db_name, "migrations", "pending_migrations.jl"))
        
        # Apply migrations
        migrate(joinpath(@__DIR__, db_name), interactive=false)
        
        # Let's check the DB schema directly
        conn = PormG.ConnectionPool.acquire_connection(settings.connections)
        tables = SQLite.tables(conn) |> DataFrame
        @test "migrationtest" in tables.name
        
        # Check columns
        columns = SQLite.columns(conn, "migrationtest") |> DataFrame
        PormG.ConnectionPool.release_connection(settings.connections, conn)
        @test "id" in columns.name
        @test "name" in columns.name
    end

    @testset "Phase 2: Add Field" begin
        write_test_models("""
        MigrationTest = Models.Model(
            id = Models.IDField(),
            name = Models.CharField(),
            age = Models.IntegerField(null=true)
        )
        """)
        
        makemigrations(joinpath(@__DIR__, db_name), interactive=false)
        migrate(joinpath(@__DIR__, db_name), interactive=false)
        
        conn = PormG.ConnectionPool.acquire_connection(settings.connections)
        columns = SQLite.columns(conn, "migrationtest") |> DataFrame
        PormG.ConnectionPool.release_connection(settings.connections, conn)
        @test "age" in columns.name
    end

    @testset "Phase 3: Drop Field" begin
        write_test_models("""
        MigrationTest = Models.Model(
            id = Models.IDField(),
            name = Models.CharField()
        )
        """)
        
        makemigrations(joinpath(@__DIR__, db_name), interactive=false)
        migrate(joinpath(@__DIR__, db_name), interactive=false)
        
        conn = PormG.ConnectionPool.acquire_connection(settings.connections)
        columns = SQLite.columns(conn, "migrationtest") |> DataFrame
        PormG.ConnectionPool.release_connection(settings.connections, conn)
        @test !("age" in columns.name)
    end

    @testset "Phase 4: Multiple Tables and Foreign Keys" begin
        write_test_models("""
        MigrationTest = Models.Model(
            id = Models.IDField(),
            name = Models.CharField()
        )
        SecondTable = Models.Model(
            id = Models.IDField(),
            test_id = Models.ForeignKey("MigrationTest", on_delete=Models.CASCADE),
            description = Models.CharField(null=true)
        )
        """)
        
        makemigrations(joinpath(@__DIR__, db_name), interactive=false)
        migrate(joinpath(@__DIR__, db_name), interactive=false)
        
        conn = PormG.ConnectionPool.acquire_connection(settings.connections)
        tables = SQLite.tables(conn) |> DataFrame
        @test "secondtable" in tables.name
        
        columns = SQLite.columns(conn, "secondtable") |> DataFrame
        PormG.ConnectionPool.release_connection(settings.connections, conn)
        @test "test_id" in columns.name
    end

    @testset "Phase 5: Indexes and Unique Constraints" begin
        write_test_models("""
        MigrationTest = Models.Model(
            id = Models.IDField(),
            name = Models.CharField(db_index=true, unique=true)
        )
        """)
        
        makemigrations(joinpath(@__DIR__, db_name), interactive=false)
        migrate(joinpath(@__DIR__, db_name), interactive=false)
        
        conn = PormG.ConnectionPool.acquire_connection(settings.connections)
        # Use raw query to check indexes in SQLite
        indices = PormG.ConnectionPool.fetch(settings.connections, "PRAGMA index_list('migrationtest')", conn=conn) |> DataFrame
        PormG.ConnectionPool.release_connection(settings.connections, conn)
        
        @test !isempty(indices)
    end

    @testset "Phase 6: Alter Field Properties (Nullability)" begin
        # Change name to allowed null
        write_test_models("""
        MigrationTest = Models.Model(
            id = Models.IDField(),
            name = Models.CharField(null=true)
        )
        """)
        
        makemigrations(joinpath(@__DIR__, db_name), interactive=false)
        migrate(joinpath(@__DIR__, db_name), interactive=false)
        
        conn = PormG.ConnectionPool.acquire_connection(settings.connections)
        columns = SQLite.columns(conn, "migrationtest") |> DataFrame
        PormG.ConnectionPool.release_connection(settings.connections, conn)
        
        row = filter(r -> r.name == "name", columns)
        @test !isempty(row)
        # In SQLite pragma, notnull=1 means NOT NULL, notnull=0 means NULL allowed
        @test row[1, :notnull] == 0
    end

    @testset "Phase 7: Rename Column" begin
        # Change 'name' to 'fullname'
        write_test_models("""
        MigrationTest = Models.Model(
            id = Models.IDField(),
            fullname = Models.CharField(null=true)
        )
        """)
        
        makemigrations(joinpath(@__DIR__, db_name), interactive=false)
        migrate(joinpath(@__DIR__, db_name), interactive=false)
        
        conn = PormG.ConnectionPool.acquire_connection(settings.connections)
        columns = SQLite.columns(conn, "migrationtest") |> DataFrame
        PormG.ConnectionPool.release_connection(settings.connections, conn)
        @test "fullname" in columns.name
    end

    @testset "Phase 8: Add More Types" begin
        write_test_models("""
        TypesTable = Models.Model(
            id = Models.IDField(),
            is_active = Models.BooleanField(default=true),
            score = Models.DecimalField(max_digits=5, decimal_places=2, null=true),
            created_at = Models.DateTimeField(null=true)
        )
        """)
        
        makemigrations(joinpath(@__DIR__, db_name), interactive=false)
        migrate(joinpath(@__DIR__, db_name), interactive=false)
        
        conn = PormG.ConnectionPool.acquire_connection(settings.connections)
        columns = SQLite.columns(conn, "typestable") |> DataFrame
        PormG.ConnectionPool.release_connection(settings.connections, conn)
        @test "is_active" in columns.name
        @test "score" in columns.name
        @test "created_at" in columns.name
    end
    
    # Cleanup after all tests
    PormG.Configuration.close_pool!(joinpath(@__DIR__, db_name))
    ispath(joinpath(@__DIR__, db_name)) && rm(joinpath(@__DIR__, db_name), recursive=true)
end
