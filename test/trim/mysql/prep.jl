# Seed the MySQL variant's database under the JIT (#1599, #1614): PormG's own DDL for Circuit and Race, the
# Monaco and Interlagos circuits and one Monaco race, so the fixture's read returns one row. The binary does
# not `migrate` (#1603).
#   PORMG_TRIM_DATABASE=pormg_trim … julia --project=test/trim/mysql test/trim/mysql/prep.jl
#
# The server comes from the same `PORMG_TRIM_*` variables as `main.jl` (`server.jl`). This script empties
# both tables before seeding, so it refuses a database whose name does not contain "trim": the integration
# suite's F1 database has `circuit` and `race` tables too, and must never be emptied from here.
using PormG, MySQL, Dates

include(joinpath(@__DIR__, "..", "db", "models.jl"))
import .models as M
include(joinpath(@__DIR__, "server.jl"))

const KEY = "f1"

server = trim_server()
occursin("trim", get(ENV, "PORMG_TRIM_DATABASE", "")) || error(
    "prep.jl empties the circuit and race tables: set PORMG_TRIM_DATABASE to a database of the " *
    "fixture's own, whose name contains \"trim\" (e.g. pormg_trim), never the integration suite's")
PormG.Configuration.register_connection(KEY, trim_url(server);
    adapter = "MySQL", env = "prod", pool_size = 1, change_db = true, change_data = true)
PormG.Models.set_models(models.MODEL_SET; key = KEY)

PormG.Migrations.ensure_table!(M.Circuit, KEY)
PormG.Migrations.ensure_table!(M.Race, KEY)
M.Race.objects.delete(allow_delete_all = true)
M.Circuit.objects.delete(allow_delete_all = true)
M.Circuit.objects.create("circuitref" => "monaco", "name" => "Circuit de Monaco", "country" => "Monaco")
M.Circuit.objects.create("circuitref" => "interlagos", "name" => "Autódromo José Carlos Pace", "country" => "Brazil")
monaco = M.Circuit.objects.filter("circuitref" => "monaco").values("circuitid").list()[1]
M.Race.objects.create("year" => 2008, "round" => 6, "circuitid" => monaco["circuitid"],
                      "name" => "Monaco Grand Prix", "date" => Date(2008, 5, 25))
println("prepped ", trim_where(server))
