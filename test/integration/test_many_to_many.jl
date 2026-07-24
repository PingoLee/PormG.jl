"""
Many-to-Many Integration Tests

Exercises ManyToManyField end-to-end against the selected integration database
(SQLite via `PORMG_DB="db_sl"` or PostgreSQL via `db_2`):

  • Auto-generated through table is created during migration bootstrap
    (see test_migration_bootstrap.jl Phase B).
  • ManyToManyManager `add`, `remove`, `clear`, `set` against the
    through table with parameterized SQL on both backends.
  • Forward-direction filter traversal (`endorsement.sponsors__name`).
  • Reverse-direction filter traversal (`sponsor.drivers__driverref`)
    using the `related_name="drivers"` declared on the field.
  • `manager.all()` returning a fluent query restricted to the related rows.
  • Empty/no-op mutators, `set` rollback on FK failure, parent-delete cascade,
    and explicit through tables without extra fields.
  • Query surface: `__@in`, `__@nin`, `Q`/`Qor`, `distinct`, `count`/`exists` on
    `manager.all()`, vector `remove`, default reverse accessor, short multi-hop reverse.

Run with:
  julia -t auto --project=. test/integration/runtests.jl
  \$env:PORMG_DB="db_sl"; julia -t 1 --project=. test/integration/runtests.jl

When run standalone, pending scratch-model tables are migrated automatically
(see `_ensure_m2m_scratch_schema!` below). A full `runtests.jl` bootstrap is still
recommended after large model changes.
"""

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

isdefined(Main, :table_exists) || include(joinpath(@__DIR__, "common_migration_setup.jl"))

import PormG.Migrations: makemigrations, migrate

# Scratch tables introduced after the original M2M suite; older DBs may lack them
# when this file is executed without `test_migration_bootstrap.jl`.
const _M2M_SCRATCH_TABLES = (
    "m2m_link_plain_scratch",
    "m2m_brand_scratch",
    "m2m_driver_default_reverse_scratch",
)

function _m2m_scratch_table_exists(pool, table_name::String)::Bool
    return Base.invokelatest(table_exists, pool, table_name)
end

function _ensure_m2m_scratch_schema!()
    pool = PormG.config[PORMG_DB_FOLDER].connections
    missing_tables = [t for t in _M2M_SCRATCH_TABLES if !_m2m_scratch_table_exists(pool, t)]
    isempty(missing_tables) && return nothing

    @info "Applying migrations for missing M2M scratch tables" db=PORMG_DB_FOLDER tables=missing_tables
    Base.invokelatest(makemigrations, PORMG_DB_FOLDER; interactive=false)
    Base.invokelatest(migrate, PORMG_DB_FOLDER; interactive=false, destructive=false)

    still_missing = [t for t in _M2M_SCRATCH_TABLES if !_m2m_scratch_table_exists(pool, t)]
    if !isempty(still_missing)
        Base.invokelatest(migrate, PORMG_DB_FOLDER; interactive=false, destructive=true)
        still_missing = [t for t in _M2M_SCRATCH_TABLES if !_m2m_scratch_table_exists(pool, t)]
    end
    if !isempty(still_missing)
        error(
            "Missing M2M scratch tables $(still_missing) on $(PORMG_DB_FOLDER). " *
            "Run test/integration/runtests.jl (migration bootstrap) or " *
            "PormG.Migrations.migrate(\"$(PORMG_DB_FOLDER)\", destructive=true).",
        )
    end
    return nothing
end

_ensure_m2m_scratch_schema!()

@testset "Many-to-Many through table operations" begin
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

    # --- ManyToManyManager.add ----------------------------------------------
    manager_x = M.M2m_driver_endorsement_scratch.sponsors(driver_x)
    manager_y = M.M2m_driver_endorsement_scratch.sponsors(driver_y)

    @test manager_x.add(sponsor_a, sponsor_b) === nothing
    # Re-adding the same pair must be idempotent (PostgreSQL: WHERE NOT EXISTS; SQLite: INSERT OR IGNORE).
    @test manager_x.add(sponsor_a) === nothing
    listed_x = manager_x.all().list()
    @test length(listed_x) == 2
    @test Set([row[:name] for row in listed_x]) == Set(["Petrolux", "AeroFuel"])

    @test manager_y.add([sponsor_b, sponsor_c]) === nothing
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

    # --- ManyToManyManager.remove -------------------------------------------
    @test manager_x.remove(sponsor_a) === nothing
    remaining_x = manager_x.all().list()
    @test length(remaining_x) == 1
    @test remaining_x[1][:name] == "AeroFuel"

    # Removing an entry that no longer exists must be a no-op (no SQL error).
    @test manager_x.remove(sponsor_a) === nothing   # returns nothing

    # --- ManyToManyManager.set ----------------------------------------------
    diff = manager_x.set(sponsor_b, sponsor_c)
    @test diff.added == 1            # sponsor_c added
    @test diff.removed == 0
    after_set = Set([row[:name] for row in manager_x.all().list()])
    @test after_set == Set(["AeroFuel", "Stratostream"])

    new_team = M.M2m_sponsor_scratch.objects.create("name" => "NewTeam")
    diff_partial = manager_x.set(sponsor_c, new_team)
    @test diff_partial.removed == 1
    @test diff_partial.added == 1
    final_set = Set([row[:name] for row in manager_x.all().list()])
    @test final_set == Set(["Stratostream", "NewTeam"])

    # set to an empty target list removes everything.
    diff_empty = manager_x.set(Any[])
    @test diff_empty.removed == 2
    @test diff_empty.added == 0
    @test isempty(manager_x.all().list())

    # --- ManyToManyManager.clear --------------------------------------------
    @test manager_y.clear() === nothing
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

    ferrari = M.M2m_sponsor_with_country_scratch.objects.create("name" => "Ferrari", "country" => italy[:id])
    petrobras = M.M2m_sponsor_with_country_scratch.objects.create("name" => "Petrobras", "country" => brazil[:id])

    driver_a = M.M2m_driver_multi_hop_scratch.objects.create("driverref" => "lec")
    driver_b = M.M2m_driver_multi_hop_scratch.objects.create("driverref" => "massa")

    M.M2m_driver_multi_hop_scratch.sponsors(driver_a).add(ferrari)
    M.M2m_driver_multi_hop_scratch.sponsors(driver_b).add(petrobras)

    # Multi-hop filter: Driver -> Sponsor -> Country
    q = M.M2m_driver_multi_hop_scratch.objects
    q.filter("sponsors__country__name" => "Italy")
    q.values("driverref")
    rows = q.list()
    @test length(rows) == 1
    @test rows[1][:driverref] == "lec"

    # Multi-hop filter reverse: Country -> Sponsor -> Driver (long default path)
    rq = M.M2m_country_scratch.objects
    rq.filter("m2m_sponsor_with_country_scratch__drivers__driverref" => "massa")
    rq.values("name")
    rrows = rq.list()
    @test length(rrows) == 1
    @test rrows[1][:name] == "Brazil"

    # Short reverse hop via related_name on the middle model (Sponsor -> Driver)
    sq = M.M2m_sponsor_with_country_scratch.objects
    sq.filter("drivers__driverref" => "massa")
    sq.values("name")
    srows = sq.list()
    @test length(srows) == 1
    @test srows[1][:name] == "Petrobras"
end

@testset "Many-to-Many advanced: explicit through model" begin
    M.M2m_membership_scratch.objects.delete(allow_delete_all=true)
    M.M2m_driver_explicit_scratch.objects.delete(allow_delete_all=true)
    M.M2m_team_scratch.objects.delete(allow_delete_all=true)

    driver = M.M2m_driver_explicit_scratch.objects.create("driverref" => "alonso")
    team_a = M.M2m_team_scratch.objects.create("name" => "Renault")
    team_b = M.M2m_team_scratch.objects.create("name" => "McLaren")

    # When using explicit through, we can still use add if the through model
    # only has the two foreign keys, OR we can use direct objects.
    # Here we verify that the ManyToManyManager still works with explicit through.
    manager = M.M2m_driver_explicit_scratch.teams(driver)
    
    # Since the explicit through model has an extra field (`joined_year`),
    # all direct mutators (add, remove, clear, set) must raise an ArgumentError (Django behavior).
    @test_throws PormGError manager.add(team_a)
    @test_throws PormGError manager.remove(team_a)
    @test_throws PormGError manager.clear()
    @test_throws PormGError manager.set(team_a)
    
    # Instead, we create the intermediate record directly using the objects manager:
    M.M2m_membership_scratch.objects.create("driver" => driver[:id], "team" => team_a[:id])
    
    # Verify the through table has the record
    through_rows = M.M2m_membership_scratch.objects.filter("driver" => driver[:id], "team" => team_a[:id]).list()
    @test length(through_rows) == 1
    
    # Verify we can still query via the M2M field
    @test length(manager.all().list()) == 1
    @test manager.all().list()[1][:name] == "Renault"

    # Test reverse traversal via explicit through
    team_q = M.M2m_team_scratch.objects.filter("drivers__driverref" => "alonso").values("name").list()
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
    manager.add(sponsor_a[:id], sponsor_b[:id])
    @test length(manager.all().list()) == 2

    # Test Transaction Rollback
    err = try
        PormG.run_in_transaction(PORMG_DB_FOLDER) do
            manager.clear()
            @test isempty(manager.all().list())
            throw(ErrorException("Simulated Failure"))
        end
        nothing
    catch e
        e
    end
    @test err !== nothing
    @test err isa ErrorException
    @test occursin("Simulated Failure", sprint(showerror, err))

    # After rollback, the 2 sponsors should still be there
    @test length(manager.all().list()) == 2
end

@testset "Many-to-Many: empty and no-op mutators" begin
    M.M2m_driver_endorsement_scratch.objects.delete(allow_delete_all=true)
    M.M2m_sponsor_scratch.objects.delete(allow_delete_all=true)

    sponsor_a = M.M2m_sponsor_scratch.objects.create("name" => "NoOpA")
    sponsor_b = M.M2m_sponsor_scratch.objects.create("name" => "NoOpB")
    driver = M.M2m_driver_endorsement_scratch.objects.create("driverref" => "noop1")

    manager = M.M2m_driver_endorsement_scratch.sponsors(driver)
    manager.add(sponsor_a, sponsor_b)
    before = Set([row[:name] for row in manager.all().list()])

    @test manager.add() === nothing   # empty-args: consistent Nothing return
    @test manager.remove() === nothing
    @test Set([row[:name] for row in manager.all().list()]) == before

    diff_noop = manager.set(sponsor_a, sponsor_b)
    @test diff_noop.added == 0
    @test diff_noop.removed == 0
    @test Set([row[:name] for row in manager.all().list()]) == before

    M.M2m_driver_endorsement_scratch.objects.delete(allow_delete_all=true)
    M.M2m_sponsor_scratch.objects.delete(allow_delete_all=true)
end

@testset "Many-to-Many: set rolls back on failure" begin
    M.M2m_driver_endorsement_scratch.objects.delete(allow_delete_all=true)
    M.M2m_sponsor_scratch.objects.delete(allow_delete_all=true)

    sponsor_a = M.M2m_sponsor_scratch.objects.create("name" => "RollbackA")
    sponsor_b = M.M2m_sponsor_scratch.objects.create("name" => "RollbackB")
    sponsor_c = M.M2m_sponsor_scratch.objects.create("name" => "RollbackC")
    driver = M.M2m_driver_endorsement_scratch.objects.create("driverref" => "rb1")

    manager = M.M2m_driver_endorsement_scratch.sponsors(driver)
    manager.add(sponsor_a, sponsor_b, sponsor_c)
    expected = Set(["RollbackA", "RollbackB", "RollbackC"])

    # Force remove to fail inside set's run_in_transaction (SQLite does not enforce
    # FK at runtime unless PRAGMA foreign_keys=ON, so bogus IDs are not reliable).
    orig_change_data = PormG.config[PORMG_DB_FOLDER].change_data
    try
        PormG.config[PORMG_DB_FOLDER].change_data = false
        err = try
            manager.set(sponsor_a, sponsor_b)
            nothing
        catch e
            e
        end
        @test err isa PormGError
        after_failed_set = Set([row[:name] for row in manager.all().list()])
        @test after_failed_set == expected
    finally
        PormG.config[PORMG_DB_FOLDER].change_data = orig_change_data
    end

    M.M2m_driver_endorsement_scratch.objects.delete(allow_delete_all=true)
    M.M2m_sponsor_scratch.objects.delete(allow_delete_all=true)
end

@testset "Many-to-Many: cascade on parent delete" begin
    M.M2m_driver_endorsement_scratch.objects.delete(allow_delete_all=true)
    M.M2m_sponsor_scratch.objects.delete(allow_delete_all=true)
    M.M2m_membership_scratch.objects.delete(allow_delete_all=true)
    M.M2m_driver_explicit_scratch.objects.delete(allow_delete_all=true)
    M.M2m_team_scratch.objects.delete(allow_delete_all=true)

    # Auto-generated through table (FK ON DELETE CASCADE on both sides).
    sponsor = M.M2m_sponsor_scratch.objects.create("name" => "CascadeSponsor")
    driver = M.M2m_driver_endorsement_scratch.objects.create("driverref" => "cascade_auto")
    M.M2m_driver_endorsement_scratch.sponsors(driver).add(sponsor)
    @test length(M.M2m_sponsor_scratch.drivers(sponsor).all().list()) == 1

    M.M2m_driver_endorsement_scratch.objects.filter("id" => driver[:id]).delete()
    @test isempty(M.M2m_sponsor_scratch.drivers(sponsor).all().list())

    # Explicit through model.
    driver_ex = M.M2m_driver_explicit_scratch.objects.create("driverref" => "cascade_ex")
    team = M.M2m_team_scratch.objects.create("name" => "CascadeTeam")
    M.M2m_membership_scratch.objects.create("driver" => driver_ex[:id], "team" => team[:id])
    @test M.M2m_membership_scratch.objects.filter("driver" => driver_ex[:id]).count() == 1

    M.M2m_driver_explicit_scratch.objects.filter("id" => driver_ex[:id]).delete()
    @test M.M2m_membership_scratch.objects.filter("driver" => driver_ex[:id]).count() == 0
    @test length(M.M2m_team_scratch.drivers(team).all().list()) == 0

    M.M2m_membership_scratch.objects.delete(allow_delete_all=true)
    M.M2m_driver_explicit_scratch.objects.delete(allow_delete_all=true)
    M.M2m_team_scratch.objects.delete(allow_delete_all=true)
    M.M2m_sponsor_scratch.objects.delete(allow_delete_all=true)
end

@testset "Many-to-Many: explicit through without extra fields" begin
    M.M2m_link_plain_scratch.objects.delete(allow_delete_all=true)
    M.M2m_driver_plain_scratch.objects.delete(allow_delete_all=true)
    M.M2m_team_plain_scratch.objects.delete(allow_delete_all=true)

    driver = M.M2m_driver_plain_scratch.objects.create("driverref" => "plain1")
    team_a = M.M2m_team_plain_scratch.objects.create("name" => "PlainA")
    team_b = M.M2m_team_plain_scratch.objects.create("name" => "PlainB")

    manager = M.M2m_driver_plain_scratch.teams(driver)
    @test manager.add(team_a, team_b) === nothing
    @test Set([row[:name] for row in manager.all().list()]) == Set(["PlainA", "PlainB"])

    diff = manager.set(team_b)
    @test diff.added == 0
    @test diff.removed == 1
    @test Set([row[:name] for row in manager.all().list()]) == Set(["PlainB"])

    M.M2m_link_plain_scratch.objects.delete(allow_delete_all=true)
    M.M2m_driver_plain_scratch.objects.delete(allow_delete_all=true)
    M.M2m_team_plain_scratch.objects.delete(allow_delete_all=true)
end

@testset "Many-to-Many: query and API surface" begin
    M.M2m_driver_endorsement_scratch.objects.delete(allow_delete_all=true)
    M.M2m_sponsor_scratch.objects.delete(allow_delete_all=true)
    M.M2m_brand_scratch.objects.delete(allow_delete_all=true)
    M.M2m_driver_default_reverse_scratch.objects.delete(allow_delete_all=true)

    petrolux = M.M2m_sponsor_scratch.objects.create("name" => "Petrolux")
    aerofuel = M.M2m_sponsor_scratch.objects.create("name" => "AeroFuel")
    stratostream = M.M2m_sponsor_scratch.objects.create("name" => "Stratostream")
    redbull = M.M2m_sponsor_scratch.objects.create("name" => "Red Bull")

    ham = M.M2m_driver_endorsement_scratch.objects.create("driverref" => "ham44")
    ver = M.M2m_driver_endorsement_scratch.objects.create("driverref" => "ver1")
    rus = M.M2m_driver_endorsement_scratch.objects.create("driverref" => "rus55")
    empty_driver = M.M2m_driver_endorsement_scratch.objects.create("driverref" => "empty0")

    ham_mgr = M.M2m_driver_endorsement_scratch.sponsors(ham)
    ver_mgr = M.M2m_driver_endorsement_scratch.sponsors(ver)
    rus_mgr = M.M2m_driver_endorsement_scratch.sponsors(rus)
    ham_mgr.add(petrolux, aerofuel)
    ver_mgr.add(stratostream)
    rus_mgr.add(petrolux)

    # Vector remove
    @test ham_mgr.remove([petrolux, aerofuel]) === nothing
    @test isempty(ham_mgr.all().list())
    ham_mgr.add(petrolux, aerofuel)

    # manager.all() terminals
    @test ham_mgr.all().count() == 2
    @test ham_mgr.all().exists() == true
    @test rus_mgr.all().count() == 1
    empty_mgr = M.M2m_driver_endorsement_scratch.sponsors(empty_driver)
    @test empty_mgr.all().count() == 0
    @test empty_mgr.all().exists() == false

    # __@in across M2M traversal
    in_q = M.M2m_driver_endorsement_scratch.objects
    in_q.filter("sponsors__name__@in" => ["Petrolux", "Stratostream"])
    in_q.values("driverref")
    in_rows = in_q.list()
    @test Set([row[:driverref] for row in in_rows]) == Set(["ham44", "ver1", "rus55"])

    # __@nin (negative filter; PormG has no .exclude() on queries)
    nin_q = M.M2m_driver_endorsement_scratch.objects
    nin_q.filter("sponsors__name__@nin" => ["Stratostream"])
    nin_q.values("driverref")
    nin_rows = nin_q.list()
    @test Set([row[:driverref] for row in nin_rows]) == Set(["ham44", "rus55"])

    # Qor across M2M traversal
    qor_q = M.M2m_driver_endorsement_scratch.objects
    qor_q.filter(Qor(
        Q("sponsors__name" => "AeroFuel"),
        Q("sponsors__name" => "Red Bull"),
    ))
    qor_q.values("driverref")
    qor_rows = qor_q.list()
    @test Set([row[:driverref] for row in qor_rows]) == Set(["ham44"])

    # distinct on a query that joins through M2M
    distinct_q = M.M2m_driver_endorsement_scratch.objects
    distinct_q.filter("sponsors__name" => "Petrolux")
    distinct_q.values("driverref")
    distinct_q.distinct()
    distinct_rows = distinct_q.list()
    @test length(distinct_rows) == 2
    @test Set([row[:driverref] for row in distinct_rows]) == Set(["ham44", "rus55"])

    # Default reverse accessor (no related_name on the field)
    brand_a = M.M2m_brand_scratch.objects.create("name" => "LegacyBrand")
    brand_b = M.M2m_brand_scratch.objects.create("name" => "FutureBrand")
    default_driver = M.M2m_driver_default_reverse_scratch.objects.create("driverref" => "def_rev1")
    default_mgr = M.M2m_driver_default_reverse_scratch.partners(default_driver)
    default_mgr.add(brand_a, brand_b)

    reverse_default_q = M.M2m_brand_scratch.objects
    reverse_default_q.filter("m2m_driver_default_reverse_scratch__driverref" => "def_rev1")
    reverse_default_q.values("name")
    reverse_default_rows = reverse_default_q.list()
    @test Set([row[:name] for row in reverse_default_rows]) == Set(["LegacyBrand", "FutureBrand"])

    M.M2m_driver_endorsement_scratch.objects.delete(allow_delete_all=true)
    M.M2m_sponsor_scratch.objects.delete(allow_delete_all=true)
    M.M2m_brand_scratch.objects.delete(allow_delete_all=true)
    M.M2m_driver_default_reverse_scratch.objects.delete(allow_delete_all=true)
end

@testset "Many-to-Many advanced: read-only guard" begin
    driver = nothing
    orig_change_data = PormG.config[PORMG_DB_FOLDER].change_data
    try
        driver = M.M2m_driver_endorsement_scratch.objects.create("driverref" => "readonly_guard_driver")

        rel = Models.get_many_to_many_relation(M.M2m_driver_endorsement_scratch, "sponsors")
        readonly_manager = PormG.QueryBuilder.ManyToManyManager(
            M.M2m_driver_endorsement_scratch,
            M.M2m_sponsor_scratch,
            rel,
            driver[:id],
        )

        PormG.config[PORMG_DB_FOLDER].change_data = false
        try
            @test_throws PormGError readonly_manager.add(1)
            @test_throws PormGError readonly_manager.remove(1)
            @test_throws PormGError readonly_manager.clear()
            @test_throws PormGError readonly_manager.set([1])
        finally
            PormG.config[PORMG_DB_FOLDER].change_data = orig_change_data
        end
    finally
        if driver !== nothing
            M.M2m_driver_endorsement_scratch.objects.filter("id" => driver[:id]).delete()
        end
    end
end
