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

# PormG.Migrations.import_models_from_postgres("db_2")
PormG.Migrations.makemigrations("db_2")

# i stoped in compare_schemas