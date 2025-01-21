using Pkg
Pkg.activate(".")

using Revise
using Infiltrator
ENV["PORMG_ENV"] = "dev"
using PormG
using DataFrames
using Test

cd("test")
cd("pg")

PormG.Configuration.load("db_2")

# teste compation of fields
import PormG: Models, Dialect

# model = safehouse.model
# field_name = safehouse.field_name
# field = safehouse.field
# current_schema = safehouse.current_schema



# PormG.Migrations.import_models_from_postgres("db_2")
PormG.Migrations.makemigrations("db_2")

PormG.Migrations.migrate("db_2")