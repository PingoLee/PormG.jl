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

query = M.Dim_teste_timezone |> object
query.filter("id" => 1)
query.update("texto" => "teste 2")














