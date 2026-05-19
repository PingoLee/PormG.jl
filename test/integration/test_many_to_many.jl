"""
Many-to-Many Integration Tests

Exercises ManyToManyField end-to-end against the selected integration database
(SQLite via `PORMG_DB="db_sl"` or PostgreSQL via `db_2`):

  • Auto-generated through table is created during migration bootstrap
    (see test_migration_bootstrap.jl Phase B).
  • ManyToManyManager `add!`, `remove!`, `clear!`, `set!` against the
    through table with parameterized SQL on both backends.
  • Forward-direction filter traversal (`endorsement.sponsors__name`).
  • Reverse-direction filter traversal (`sponsor.drivers__driverRef`)
    using the `related_name="drivers"` declared on the field.
  • `manager.all()` returning a fluent query restricted to the related rows.

Run with:
  julia -t auto --project=. test/integration/runtests.jl
  \$env:PORMG_DB="db_sl"; julia -t 1 --project=. test/integration/runtests.jl
"""

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

@testset "Many-to-Many through table operations" begin
    settings = PormG.config[PORMG_DB_FOLDER]

    # Start each run from an empty M2M state so re-runs are deterministic.
    M.M2m_driver_endorsement_scratch.objects.delete(allow_delete_all=true)
    M.M2m_sponsor_scratch.objects.delete(allow_delete_all=true)

    sponsor_a = M.M2m_sponsor_scratch.objects.create("name" => "Petrolux")
    sponsor_b = M.M2m_sponsor_scratch.objects.create("name" => "AeroFuel")
    sponsor_c = M.M2m_sponsor_scratch.objects.create("name" => "Stratostream")

    driver_x = M.M2m_driver_endorsement_scratch.objects.create("driverref" => "ham44")
    driver_y = M.M2m_driver_endorsement_scratch.objects.create("driverref" => "ver1")

    @test sponsor_a[:id] isa Integer
    @test driver_x[:id] isa Integer

    # --- ManyToManyManager.add! ----------------------------------------------
    manager_x = M.M2m_driver_endorsement_scratch.sponsors(driver_x)
    manager_y = M.M2m_driver_endorsement_scratch.sponsors(driver_y)

    @test manager_x.add!(sponsor_a, sponsor_b) === nothing
    # Re-adding the same pair must be idempotent (ON CONFLICT DO NOTHING / OR IGNORE).
    @test manager_x.add!(sponsor_a) === nothing
    listed_x = manager_x.all().list()
    @test length(listed_x) == 2
    @test Set([row[:name] for row in listed_x]) == Set(["Petrolux", "AeroFuel"])

    @test manager_y.add!([sponsor_b, sponsor_c]) === nothing
    @test length(manager_y.all().list()) == 2

    # --- Forward filter traversal --------------------------------------------
    forward_q = M.M2m_driver_endorsement_scratch.objects
    forward_q.filter("sponsors__name" => "Petrolux")
    forward_q.values("driverref")
    forward_rows = forward_q.list()
    @test length(forward_rows) == 1
    @test forward_rows[1][:driverref] == "ham44"

    # --- Reverse filter traversal via related_name ---------------------------
    reverse_q = M.M2m_sponsor_scratch.objects
    reverse_q.filter("drivers__driverref" => "ver1")
    reverse_q.values("name")
    reverse_rows = reverse_q.list()
    @test Set([row[:name] for row in reverse_rows]) == Set(["AeroFuel", "Stratostream"])

    # --- ManyToManyManager.remove! -------------------------------------------
    @test manager_x.remove!(sponsor_a) === nothing
    remaining_x = manager_x.all().list()
    @test length(remaining_x) == 1
    @test remaining_x[1][:name] == "AeroFuel"

    # Removing an entry that no longer exists must be a no-op (no SQL error).
    @test manager_x.remove!(sponsor_a) === nothing   # returns nothing

    # --- ManyToManyManager.set! ----------------------------------------------
    diff = manager_x.set!(sponsor_b, sponsor_c)
    @test diff.added == 1            # sponsor_c added
    @test diff.removed == 0
    after_set = Set([row[:name] for row in manager_x.all().list()])
    @test after_set == Set(["AeroFuel", "Stratostream"])

    # set! to an empty target list removes everything.
    diff_empty = manager_x.set!(Any[])
    @test diff_empty.removed == 2
    @test diff_empty.added == 0
    @test isempty(manager_x.all().list())

    # --- ManyToManyManager.clear! --------------------------------------------
    @test manager_y.clear!() === nothing
    @test isempty(manager_y.all().list())

    # Final cleanup so subsequent test files start from a known-empty M2M state.
    M.M2m_driver_endorsement_scratch.objects.delete(allow_delete_all=true)
    M.M2m_sponsor_scratch.objects.delete(allow_delete_all=true)
end

@testset "Many-to-Many advanced: multi-hop joins" begin
    # Cleanup
    M.M2m_driver_multi_hop_scratch.objects.delete(allow_delete_all=true)
    M.M2m_sponsor_with_country_scratch.objects.delete(allow_delete_all=true)
    M.M2m_country_scratch.objects.delete(allow_delete_all=true)

    italy = M.M2m_country_scratch.objects.create("name" => "Italy")
    brazil = M.M2m_country_scratch.objects.create("name" => "Brazil")

    ferrari = M.M2m_sponsor_with_country_scratch.objects.create("name" => "Ferrari", "country" => italy)
    petrobras = M.M2m_sponsor_with_country_scratch.objects.create("name" => "Petrobras", "country" => brazil)

    driver_a = M.M2m_driver_multi_hop_scratch.objects.create("driverref" => "lec")
    driver_b = M.M2m_driver_multi_hop_scratch.objects.create("driverref" => "massa")

    M.M2m_driver_multi_hop_scratch.sponsors(driver_a).add!(ferrari)
    M.M2m_driver_multi_hop_scratch.sponsors(driver_b).add!(petrobras)

    # Multi-hop filter: Driver -> Sponsor -> Country
    q = M.M2m_driver_multi_hop_scratch.objects
    q.filter("sponsors__country__name" => "Italy")
    q.values("driverref")
    rows = q.list()
    @test length(rows) == 1
    @test rows[1][:driverref] == "lec"

    # Multi-hop filter reverse: Country -> Sponsor -> Driver
    rq = M.M2m_country_scratch.objects
    rq.filter("m2m_sponsor_with_country_scratch__drivers__driverref" => "massa")
    rq.values("name")
    rrows = rq.list()
    @test length(rrows) == 1
    @test rrows[1][:name] == "Brazil"
end

@testset "Many-to-Many advanced: explicit through model" begin
    M.M2m_membership_scratch.objects.delete(allow_delete_all=true)
    M.M2m_driver_explicit_scratch.objects.delete(allow_delete_all=true)
    M.M2m_team_scratch.objects.delete(allow_delete_all=true)

    driver = M.M2m_driver_explicit_scratch.objects.create("driverref" => "alonso")
    team_a = M.M2m_team_scratch.objects.create("name" => "Renault")
    team_b = M.M2m_team_scratch.objects.create("name" => "McLaren")

    # When using explicit through, we can still use add! if the through model
    # only has the two foreign keys, OR we can use direct objects.
    # Here we verify that the ManyToManyManager still works with explicit through.
    manager = M.M2m_driver_explicit_scratch.teams(driver)
    manager.add!(team_a)
    
    # Verify the through table has the record
    through_rows = M.M2m_membership_scratch.objects.filter("driver" => driver[:id], "team" => team_a[:id]).list()
    @test length(through_rows) == 1
    
    # Verify we can still query via the M2M field
    @test length(manager.all().list()) == 1
    @test manager.all().list()[1][:name] == "Renault"

    # Test reverse traversal via explicit through
    team_q = M.M2m_team_scratch.objects.filter("drivers__driverref" => "alonso").list()
    @test length(team_q) == 1
    @test team_q[1][:name] == "Renault"
end

@testset "Many-to-Many advanced: transactions and raw IDs" begin
    M.M2m_driver_endorsement_scratch.objects.delete(allow_delete_all=true)
    M.M2m_sponsor_scratch.objects.delete(allow_delete_all=true)

    driver = M.M2m_driver_endorsement_scratch.objects.create("driverref" => "vettel")
    sponsor_a = M.M2m_sponsor_scratch.objects.create("name" => "Red Bull")
    sponsor_b = M.M2m_sponsor_scratch.objects.create("name" => "Aston Martin")

    # Test Raw ID support
    manager = M.M2m_driver_endorsement_scratch.sponsors(driver[:id])
    manager.add!(sponsor_a[:id], sponsor_b[:id])
    @test length(manager.all().list()) == 2

    # Test Transaction Rollback
    try
        PormG.run_in_transaction(PORMG_DB_FOLDER) do
            manager.clear!()
            @test isempty(manager.all().list())
            throw(ErrorException("Simulated Failure"))
        end
    catch e
        # ignore
    end

    # After rollback, the 2 sponsors should still be there
    @test length(manager.all().list()) == 2
end

@testset "Many-to-Many advanced: read-only guard" begin
    driver = M.M2m_driver_endorsement_scratch.objects.list()[1]
    
    # Create a mock read-only settings
    readonly_settings = PormG.Configuration.Settings(
        connections = PormG.config[PORMG_DB_FOLDER].connections,
        change_data = false
    )
    
    # We need to temporarily inject this settings or use a mock.
    # Since we can't easily swap global config for one call without side effects,
    # Manually construct a manager with the proper constructor
    rel = Models.get_many_to_many_relation(M.M2m_driver_endorsement_scratch, "sponsors")
    readonly_manager = PormG.QueryBuilder.ManyToManyManager(
        M.M2m_driver_endorsement_scratch,
        M.M2m_sponsor_scratch,
        rel,
        driver[:id]
    )
    
    # Temporarily set change_data to false for the connection to verify the guard
    orig_change_data = PormG.config[PORMG_DB_FOLDER].change_data
    PormG.config[PORMG_DB_FOLDER].change_data = false
    try
        @test_throws ArgumentError readonly_manager.add!(1)
        @test_throws ArgumentError readonly_manager.remove!(1)
        @test_throws ArgumentError readonly_manager.clear!()
        @test_throws ArgumentError readonly_manager.set!([1])
    finally
        PormG.config[PORMG_DB_FOLDER].change_data = orig_change_data
    end
end
