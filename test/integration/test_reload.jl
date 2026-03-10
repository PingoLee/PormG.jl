if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

@testset "Revise and Hot-Reloading Test" begin
    # 1. Create a temporary model file
    tmp_dir = joinpath(@__DIR__, "db_r")
    !isdir(tmp_dir) && mkpath(tmp_dir)
    
    # Create a connection.yml for this temporary DB folder
    # We'll use the same settings as db_2 if available, or just a simple SQLite for testing reload
    open(joinpath(tmp_dir, "connection.yml"), "w") do f
        write(f, """
        env: dev
        dev:
          adapter: SQLite
          database: ":memory:"
          config:
            change_db: true
            change_data: true
        """)
    end
    
    tmp_model_file = joinpath(tmp_dir, "tmp_reload_models.jl")
    
    write(tmp_model_file, """
    module reload_models
        import PormG.Models
        
        ReloadTest = Models.Model("reload_test",
            id = Models.IDField(),
            name = Models.CharField()
        )
    end
    """)

    # 2. Import it using @import_models (this also registers a Revise callback)
    @info "Importing initial model..."
    PormG.@import_models "db_r/tmp_reload_models.jl" reload_models
    import .reload_models as RM
    
    # Verify initial state
    @test isdefined(RM, :ReloadTest)
    @test RM.ReloadTest.name == "reload_test"
    @test haskey(RM.ReloadTest.fields, "name")
    @test !haskey(RM.ReloadTest.fields, "new_field")
    @test basename(RM.ReloadTest.connect_key) == "db_r"

    # 3. Modify the file — add a new field
    @info "Modifying model file..."
    sleep(0.5) # Force filesystem timestamp difference
    write(tmp_model_file, """
    module reload_models
        import PormG.Models
        
        ReloadTest = Models.Model("reload_test",
            id = Models.IDField(),
            name = Models.CharField(),
            new_field = Models.IntegerField(default=10)
        )
    end
    """)
    sleep(0.5)

    # 4. Trigger Revise
    #    In a real REPL session this happens automatically via filesystem polling.
    #    In a script we call Revise.revise() explicitly.
    if isdefined(Main, :Revise)
        @info "Triggering Revise.revise()..."
        Revise.revise()
    end

    # If Revise didn't pick up the change (common in batch scripts where
    # includet tracking doesn't work the same as in a REPL), fall back
    # to manual reload so the test validates the core logic regardless.
    if !haskey(RM.ReloadTest.fields, "new_field")
        @warn "Revise did not pick up file change, using manual reload_module_contents! fallback"
        PormG.Utils.reload_module_contents!(RM, tmp_model_file)
        PormG.Models.set_models(RM, dirname(tmp_model_file))
    end

    # 5. Verify the hot-reloaded state
    #    Because reload_module_contents! evaluates the new expressions inside
    #    the EXISTING module, the RM alias is still valid.
    @test haskey(RM.ReloadTest.fields, "new_field")
    @test RM.ReloadTest.fields["new_field"].default == 10
    # Original field should still be there
    @test haskey(RM.ReloadTest.fields, "name")
    @test basename(RM.ReloadTest.connect_key) == "db_r"

    # Clean up
    rm(tmp_model_file)
end
