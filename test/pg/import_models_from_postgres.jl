# This script is used to create the database and tables for the PormG package.
using Pkg
Pkg.activate(".")

using Revise
using PormG
using DataFrames

cd("test")
cd("pg")

PormG.Configuration.load("db")

PormG.Migrations.import_models_from_postgres("db", include_table=["just_a_test_deletion"])