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
import PormG.QueryBuilder: Sum, Avg, Case, When, Count, Q, Qor, page

# load models
# Base.include(PormG, "db/automatic_models.jl")
# import PormG.automatic_models as AM

# query = AM.Dim_uf |> object
# df = query |> list |> DataFrame

Base.include(PormG, "db_2/models.jl")
import PormG.models as M

# query = M.Dim_teste_timezone |> object
# dt = query.create("texto" => "teste")

# query = M.Dim_teste_timezone |> object
# query.filter("id" => 2)
# query.update("texto" => "teste 3")

# inser

path_load = "/home/pingo02/BackUp/pormg/f1/status.csv"
df = CSV.File(path_load) |> DataFrame

query = M.Status |> object

for row in eachrow(df)
    dt = query.create("statusid" => row.statusId, "status" => row.status)
    println(row.statusId)
end

# bulk_insert

query = M.Circuit |> object

path_load = "/home/pingo02/BackUp/pormg/f1/circuits.csv"
df = CSV.File(path_load) |> DataFrame

bulk_insert(query, df)


query = M.Race |> object

path_load = "/home/pingo02/BackUp/pormg/f1/races.csv"
df = CSV.File(path_load) |> DataFrame

bulk_insert(query, df) # a error is expected

# pre-processing
for col in [:fp1_date, :fp1_time, :fp2_date, :fp2_time, :fp3_date, :fp3_time, :quali_date, :quali_time, :sprint_date, :sprint_time, :time]
    df[!, col] = map(x -> ismissing(x) || x == "\\N" ? missing : x, df[!, col])
end

bulk_insert(query, df)


query = M.Driver |> object
df = CSV.File("/home/pingo02/BackUp/pormg/f1/drivers.csv") |> DataFrame

bulk_insert(query, df) # a error is expected

for col in [:number]
    df[!, col] = map(x -> ismissing(x) || x == "\\N" ? missing : x, df[!, col])
end

bulk_insert(query, df)

query = M.Constructor |> object
df = CSV.File("/home/pingo02/BackUp/pormg/f1/constructors.csv") |> DataFrame
bulk_insert(query, df)

query = M.Result |> object
df = CSV.File("/home/pingo02/BackUp/pormg/f1/results.csv") |> DataFrame
bulk_insert(query, df) # a error is expected

for col in [:position, :time, :milliseconds, :fastestlap, :rank, :fastestlaptime, :fastestlapspeed, :number]
    df[!, col] = map(x -> ismissing(x) || x == "\\N" ? missing : x, df[!, col])
end

bulk_insert(query, df)


# test querys

query = M.Result |> object
query.filter("driverid__surname" => "Hamilton", "fastestlaptime__@isnull" => false);
query.values("driverid__surname", "driverid__forename", "position", "time", "fastestlaptime", "fastestlapspeed");
query.order_by("-fastestlapspeed");
page(query, 10)

df = query |> list |> DataFrame

query = M.Circuit |> object;
query.values("circuitid", "name", "location", "country");
query.order_by("circuitid");
page(query, 10);

df = query |> list |> DataFrame

df.location = map(x -> ismissing(x) ? missing : uppercase(x), df.location)
df.country = map(x -> ismissing(x) ? missing : uppercase(x), df.country)


# bulk_update

bulk_update(query, df)


# insert fake data in the table Just_a_test_deletion
query = M.Just_a_test_deletion |> object
query.create("name" => "test", "test_result" => 1)
query.create("name" => "test", "test_result" => 2)
query.create("name" => "test", "test_result" => 3)

# check insertion
query = M.Just_a_test_deletion |> object
query.filter("name" => "test")
query.values("id", "name", "test_result__constructorid__name")

df2 = query |> list |> DataFrame