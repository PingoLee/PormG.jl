using Pkg
Pkg.activate(".")

using Revise
using PormG

cd("test")

PormG.Configuration.load()

# test importation
schemas = PormG.Migrations.get_database_schema()

sql = schemas["rel_avan"]["sql"]

# import PormG.Migrations: convertSQLToModel

teste = PormG.Migrations.convertSQLToModel(sql)

PormG.Model_to_str(teste)

PormG.Migrations.import_models_from_sql()

Base.include(PormG, "db/models/automatic_models.jl")
import PormG.Automatic_models as AM