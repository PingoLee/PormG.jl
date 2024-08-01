using Pkg
Pkg.activate(".")

using Revise
using PormG
using DataFrames

cd("test")

PormG.Configuration.load()

# test importation
schemas = PormG.Migrations.get_database_schema()

# test conversion with multiples foreign keys
sql = schemas["rel_cols"]["sql"]
teste = PormG.Migrations.convertSQLToModel(sql)
PormG.Model_to_str(teste)

# test conversion with reserved words
sql = schemas["banco_cols"]["sql"]
teste = PormG.Migrations.convertSQLToModel(sql)
PormG.Model_to_str(teste)

PormG.Migrations.import_models_from_sql()

Base.include(PormG, "db/models/automatic_models.jl")
import PormG.Automatic_models as AM

