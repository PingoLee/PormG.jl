# Seed a fresh run directory under the JIT: one SQLite file with PormG's own DDL, the Monaco and
# Interlagos circuits and one Monaco race. The binary does not `migrate` (#1603).
#   julia --project=test/trim test/trim/prep.jl <run dir>
using TrimF1, PormG, Dates
const M = TrimF1.M

dir = abspath(ARGS[1])
mkpath(dir)
rm(joinpath(dir, "f1.sqlite"); force = true)
TrimF1.boot!(dir)
PormG.Migrations.ensure_table!(M.Circuit, TrimF1.KEY)
PormG.Migrations.ensure_table!(M.Race, TrimF1.KEY)
M.Circuit.objects.create("circuitref" => "monaco", "name" => "Circuit de Monaco", "country" => "Monaco")
M.Circuit.objects.create("circuitref" => "interlagos", "name" => "Autódromo José Carlos Pace", "country" => "Brazil")
monaco = M.Circuit.objects.filter("circuitref" => "monaco").values("circuitid").list()[1]
M.Race.objects.create("year" => 2008, "round" => 6, "circuitid" => monaco["circuitid"],
                      "name" => "Monaco Grand Prix", "date" => Date(2008, 5, 25))
println("prepped ", dir)
