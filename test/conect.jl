using Pkg
Pkg.activate(".")

using Revise
using PormG
using DataFrames

cd("test")

PormG.Configuration.load()

# # test importation
# schemas = PormG.Migrations.get_database_schema()

# sql = schemas["rel_avan"]["sql"]

# # import PormG.Migrations: convertSQLToModel

# teste = PormG.Migrations.convertSQLToModel(sql)

# PormG.Model_to_str(teste)

# PormG.Migrations.import_models_from_sql()

Base.include(PormG, "db/models/automatic_models.jl")
import PormG.Automatic_models as AM

query = AM.rel_avan |> object
# PormG.Modcels.set_models(AM)


query.values("id", "definition", "rel_id__nome").filter("id__gte" => 1)

query.query()

instruct = PormG.InstrucObject(text = "", 
    object =  query.object,
    select = [], 
    join = [],
    _where = [],
    group = [],
    having = [],
    order = [],
    df_join = DataFrames.DataFrame(a=String[], b=String[], key_a=String[], key_b=String[], how=String[], 
    alias_b=String[], alias_a=String[]),
  )


  instruct.object |> parentmodule


PormG.QueryBuilder.get_select_query(query.object, instruct)


PormG.QueryBuilder.get_filter_query(query.object, instruct)

fields = fieldnames(typeof(query.object))

