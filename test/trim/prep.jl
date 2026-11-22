# Seed a fresh run directory under the JIT: one SQLite file with PormG's own DDL, the Monaco and
# Interlagos circuits, one Monaco race and one Brazilian race (the second row of the comparison and order
# steps, `tools/reads.jl`), and a pit stop and a driver on the Monaco race (`cascade_step`, `tools/writes.jl`). The
# binary does not `migrate` (#1603).
#   julia --project=test/trim test/trim/prep.jl <run dir>
using TrimF1, PormG, Dates
const M = TrimF1.M

dir = abspath(ARGS[1])
mkpath(dir)
rm(joinpath(dir, "f1.sqlite"); force = true)
TrimF1.boot!(dir)
PormG.Migrations.ensure_table!(M.Circuit, TrimF1.KEY)
PormG.Migrations.ensure_table!(M.Race, TrimF1.KEY)
PormG.Migrations.ensure_table!(M.PitStop, TrimF1.KEY)
PormG.Migrations.ensure_table!(M.Driver, TrimF1.KEY)
PormG.Migrations.ensure_table!(M.Constructor, TrimF1.KEY)
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
# The default home circuit at its fixed id, and a seeded chain of constructors on it (`set_default_step`,
# `self_cascade_step`, `tools/writes.jl`): Toleman became Benetton, which became Renault. Both steps leave these as they
# are.
M.Circuit.objects.create("circuitid" => TrimF1.models.DEFAULT_CIRCUIT_ID, "circuitref" => "default", "name" => "No circuit",
                         "country" => "None")
M.Constructor.objects.create("name" => "Toleman", "home_circuitid" => TrimF1.models.DEFAULT_CIRCUIT_ID)
toleman = M.Constructor.objects.filter("name" => "Toleman").values("constructorid").list()[1]
M.Constructor.objects.create("name" => "Benetton", "parentid" => toleman["constructorid"],
                             "home_circuitid" => TrimF1.models.DEFAULT_CIRCUIT_ID)
benetton = M.Constructor.objects.filter("name" => "Benetton").values("constructorid").list()[1]
M.Constructor.objects.create("name" => "Renault", "parentid" => benetton["constructorid"],
                             "home_circuitid" => TrimF1.models.DEFAULT_CIRCUIT_ID)
println("prepped ", dir)
