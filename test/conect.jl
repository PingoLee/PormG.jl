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


# PormG.Models.set_models(AM)

# query = AM.rel_avan |> object
# query.values("id", "definition", "rel_id__nome").filter("id__gte" => 1)

# @time query.query()

# query = AM.rel_avan |> object
# query.values("id", "definition", "rel_id__nome", "rel_id__opc_cruz_id__nome", "rel_id__opc_cruz_id__b1_id__nome", "rel_id__obs" ).filter("rel_id__opc_cruz_id__b1_id" => 1)
# @time query.query()

# reverso curto
query = AM.bancos |> object
query.values("rel_cols__cruz_rel_id", "rel_cols__id").filter("id" => 1)
@time query.query()

# # reverso muitos com problema por conta da importação
# query = AM.bancos |> object
# query.values("rel_cols__cruz_rel_id", "rel_cols__cruz_rel_id__nome", "rel_cols__cruz_rel_id__var_rel", "opc_cruzamento__nome").filter("id" => 1)
# @time query.query()

# reverso longo
query = AM.bancos |> object
query.values("opc_cruzamento__st_cruz__linkado").filter("id" => 1)
@time query.query()

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

