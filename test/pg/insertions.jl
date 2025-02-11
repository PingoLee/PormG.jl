using Pkg
Pkg.activate(".")

using Revise
using Infiltrator
ENV["PORMG_ENV"] = "dev"
using PormG
using DataFrames
using CSV
using Test

cd("test")
cd("pg")

# PormG.Configuration.load()
PormG.Configuration.load("db_2")

# teste compation of fields
import PormG: Models, Dialect

# load models
# Base.include(PormG, "db/automatic_models.jl")
# import PormG.automatic_models as AM

# query = AM.Dim_uf |> object
# df = query |> list |> DataFrame

Base.include(PormG, "db_2/models.jl")
import PormG.models as M

# query = M.Dim_uf |> object
# row = df[19, :]
# dt = query.create("nome" => row.nome, "sigla" => "row.sigla")

# query = M.Dim_teste_timezone |> object
# dt = query.create("texto" => "teste")

# query = M.Dim_teste_timezone |> object
# query.filter("id" => 2)
# query.update("texto" => "teste 3")



# path_load = "/home/pingo02/BackUp/pormg/f1/status.csv"
# df = CSV.File(path_load) |> DataFrame

# query = M.Status |> object

# for row in eachrow(df)
#     dt = query.create("statusid" => row.statusId, "status" => row.status)
#     println(row.statusId)
# end

# bulk_insert

query = M.Circuit |> object

path_load = "/home/pingo02/BackUp/pormg/f1/circuits.csv"
df = CSV.File(path_load) |> DataFrame

bulk_insert(query, df)


query = M.Race |> object

path_load = "/home/pingo02/BackUp/pormg/f1/races.csv"
df = CSV.File(path_load) |> DataFrame

bulk_insert(query, df)

# pre-processing
for col in [:fp1_date, :fp1_time, :fp2_date, :fp2_time, :fp3_date, :fp3_time, :quali_date, :quali_time, :sprint_date, :sprint_time, :time]
    df[!, col] = map(x -> ismissing(x) || x == "\\N" ? missing : x, df[!, col])
end

bulk_insert(query, df)


query = M.Driver |> object
df = CSV.File("/home/pingo02/BackUp/pormg/f1/drivers.csv") |> DataFrame

bulk_insert(query, df)






