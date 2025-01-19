using Pkg
Pkg.activate(".")

using Revise
ENV["PORMG_ENV"] = "dev"
using PormG
using DataFrames
using Test

cd("test")
cd("pg")

PormG.Configuration.load("db_2")

# teste compation of fields
Base.include(PormG, "db_2/models.jl")
import PormG.models as AM


PormG.Models.get_all_fields(AM.Dim_municipio)

PormG.Models.compare_model_fields(AM.Dim_municipio,AM.Dim_municipio)




# PormG.Migrations.import_models_from_postgres("db_2")
PormG.Migrations.makemigrations("db_2")

PormG.Migrations.migrate("db_2")