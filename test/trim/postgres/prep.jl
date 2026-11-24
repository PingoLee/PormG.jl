# Seed the Postgres.jl variant's database under the JIT (#1599, #1614): PormG's own DDL for Circuit, Race, PitStop and
# Driver; the Monaco and Interlagos circuits and one Monaco race, so the fixture's read returns one row; one
# Brazilian race for the comparison and order steps (`../tools/reads.jl`); and a pit stop and a driver on the
# Monaco race (`cascade_step`, `../tools/writes.jl`). The binary does not `migrate` (#1603).
#   PORMG_TRIM_DATABASE=pormg_trim … julia --project=test/trim/postgres test/trim/postgres/prep.jl
#
# The server comes from the same `PORMG_TRIM_*` variables as `main.jl` (`../tools/server.jl`). This script
# empties the fixture's tables before seeding, so it refuses a database whose name does not contain "trim": the
# integration suite's F1 database has `circuit`, `race` and `driver` tables too, and must never be emptied from here.
using PormG, Postgres, Dates

include(joinpath(@__DIR__, "..", "db", "models.jl"))
import .models as M
include(joinpath(@__DIR__, "..", "tools", "server.jl"))

const KEY = "f1"

server = trim_server()
occursin("trim", get(ENV, "PORMG_TRIM_DATABASE", "")) || error(
    "prep.jl empties the circuit, race, pit stop and driver tables: set PORMG_TRIM_DATABASE to a database of the " *
    "fixture's own, whose name contains \"trim\" (e.g. pormg_trim), never the integration suite's")
PormG.Configuration.register_connection(KEY, trim_url(server, "postgresql");
    adapter = "PostgreSQL", postgres_driver = "Postgres", env = "prod", pool_size = 1,
    change_db = true, change_data = true)
PormG.Models.set_models(models.MODEL_SET; key = KEY)

PormG.Migrations.ensure_table!(M.Circuit, KEY)
PormG.Migrations.ensure_table!(M.Race, KEY)
PormG.Migrations.ensure_table!(M.PitStop, KEY)
PormG.Migrations.ensure_table!(M.Driver, KEY)
PormG.Migrations.ensure_table!(M.Constructor, KEY)
PormG.Migrations.ensure_table!(M.Result, KEY)
PormG.Migrations.ensure_table!(M.Season, KEY)
# The results first: they keep their race (`PROTECT`) and driver (`RESTRICT`) from being deleted below. A season's
# reference to the one before is cleared first, as the constructors' below.
M.Result.objects.delete(allow_delete_all = true)
M.Season.objects.filter("previousid__@isnull" => false).update("previousid" => nothing)
M.Season.objects.delete(allow_delete_all = true)
# A self-referential CASCADE is not deleted under `allow_delete_all` (PormG refuses the loop): clear the chain's
# references first, then delete every constructor.
M.Constructor.objects.filter("parentid__@isnull" => false).update("parentid" => nothing)
M.Constructor.objects.delete(allow_delete_all = true)
M.PitStop.objects.delete(allow_delete_all = true)
M.Driver.objects.delete(allow_delete_all = true)
M.Race.objects.delete(allow_delete_all = true)
M.Circuit.objects.delete(allow_delete_all = true)
M.Circuit.objects.create("circuitref" => "monaco", "name" => "Circuit de Monaco", "country" => "Monaco")
M.Circuit.objects.create("circuitref" => "interlagos", "name" => "Autódromo José Carlos Pace", "country" => "Brazil")
monaco = M.Circuit.objects.filter("circuitref" => "monaco").values("circuitid").list()[1]
M.Race.objects.create("year" => 2008, "round" => 6, "circuitid" => monaco["circuitid"],
                      "name" => "Monaco Grand Prix", "date" => Date(2008, 5, 25))
interlagos = M.Circuit.objects.filter("circuitref" => "interlagos").values("circuitid").list()[1]
M.Race.objects.create("year" => 2008, "round" => 18, "circuitid" => interlagos["circuitid"],
                      "name" => "Brazilian Grand Prix", "date" => Date(2008, 11, 2))
monaco_race = M.Race.objects.filter("year" => 2008, "round" => 6).values("raceid").list()[1]
# A child of each kind on the seeded Monaco race (#1694): `cascade_step` (`tools/writes.jl`) deletes a race of its own
# and checks that these two are left as they are.
M.PitStop.objects.create("raceid" => monaco_race["raceid"], "stop" => 1, "lap" => 20)
M.Driver.objects.create("surname" => "Piquet", "debut_raceid" => monaco_race["raceid"])
# A result of the seeded Monaco race, by its driver (#1694): neither can be deleted (`delete_rules_step`).
piquet = M.Driver.objects.filter("surname" => "Piquet").values("driverid").list()[1]
M.Result.objects.create("raceid" => monaco_race["raceid"], "driverid" => piquet["driverid"], "position" => 1)
# The default home circuit at its fixed id, and a seeded chain of constructors on it (`set_default_step`,
# `self_cascade_step`, `tools/writes.jl`): Toleman became Benetton, which became Renault. Both steps leave these as they
# are.
M.Circuit.objects.create("circuitid" => models.DEFAULT_CIRCUIT_ID, "circuitref" => "default", "name" => "No circuit",
                         "country" => "None")
M.Constructor.objects.create("name" => "Toleman", "home_circuitid" => models.DEFAULT_CIRCUIT_ID)
toleman = M.Constructor.objects.filter("name" => "Toleman").values("constructorid").list()[1]
M.Constructor.objects.create("name" => "Benetton", "parentid" => toleman["constructorid"],
                             "home_circuitid" => models.DEFAULT_CIRCUIT_ID)
benetton = M.Constructor.objects.filter("name" => "Benetton").values("constructorid").list()[1]
M.Constructor.objects.create("name" => "Renault", "parentid" => benetton["constructorid"],
                             "home_circuitid" => models.DEFAULT_CIRCUIT_ID)
# A trigger that skips one race's insert (#1694): `returning_refused_step` (`main.jl`) creates that race, and `create`
# meets an `INSERT … RETURNING` that returns no row. Raw SQL: no ORM call creates a trigger.
settings = PormG.Configuration.get_settings(KEY)
fetch(settings, raw"""CREATE OR REPLACE FUNCTION pormg_trim_skip_insert() RETURNS trigger AS $$
BEGIN
  IF NEW.name = 'Skipped Grand Prix' THEN RETURN NULL; END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql""")
fetch(settings, "DROP TRIGGER IF EXISTS pormg_trim_skip_insert ON race")
fetch(settings, "CREATE TRIGGER pormg_trim_skip_insert BEFORE INSERT ON race FOR EACH ROW EXECUTE FUNCTION pormg_trim_skip_insert()")
println("prepped ", trim_where(server))
