# This file is a tutorial for the PormG insert at data in the PostgreSQL database.
using Pkg
Pkg.activate(".")

using Revise
using Infiltrator
using PormG
using DataFrames
using CSV

cd("test")
cd("pg")

# PormG.Configuration.load()
PormG.Configuration.load("db_2")

# import PormG: Models, Dialect
import PormG.QueryBuilder: Sum, Avg, Case, When, Count, Q, Qor, page # Important: to import this to use the functions in the query

# First load the models
Base.include(PormG, "db_2/models.jl")
import PormG.models as M


# Now you can use the models to insert data in the database one by one
path_load = joinpath("f1", "status.csv")
df = CSV.File(path_load) |> DataFrame

query = M.Status |> object;

for row in eachrow(df)
    dt = query.create("statusid" => row.statusId, "status" => row.status)
    println(row.statusId)
end

# Now you can use bulk_insert to insert data in the database in bulk
query = M.Circuit |> object;
path_load = joinpath("f1", "circuits.csv")
df = CSV.File(path_load) |> DataFrame
bulk_insert(query, df)


query = M.Race |> object;
path_load = joinpath("f1", "races.csv")
df = CSV.File(path_load) |> DataFrame

bulk_insert(query, df) # a error is expected
# ArgumentError: Error in bulk_insert, the field fp1_date in row 1 has a value that can't be formatted: \N

# pre-processing
for col in [:fp1_date, :fp1_time, :fp2_date, :fp2_time, :fp3_date, :fp3_time, :quali_date, :quali_time, :sprint_date, :sprint_time, :time]
    df[!, col] = map(x -> ismissing(x) || x == "\\N" ? missing : x, df[!, col])
end

bulk_insert(query, df) # now it should work

query = M.Driver |> object;
df = CSV.File(joinpath("f1", "drivers.csv")) |> DataFrame
for col in [:number]
    df[!, col] = map(x -> ismissing(x) || x == "\\N" ? missing : x, df[!, col])
end
bulk_insert(query, df)

query = M.Constructor |> object;
df = CSV.File(joinpath("f1", "constructors.csv")) |> DataFrame
bulk_insert(query, df)

query = M.Result |> object;
df = CSV.File(joinpath("f1", "results.csv")) |> DataFrame
for col in [:position, :time, :milliseconds, :fastestlap, :rank, :fastestlaptime, :fastestlapspeed, :number]
    df[!, col] = map(x -> ismissing(x) || x == "\\N" ? missing : x, df[!, col])
end
bulk_insert(query, df)


# # test querys

# query = M.Result |> object
# query.filter("driverid__surname" => "Hamilton", "fastestlaptime__@isnull" => false);
# query.values("driverid__surname", "driverid__forename", "position", "time", "fastestlaptime", "fastestlapspeed");
# query.order_by("-fastestlapspeed");
# page(query, 10)

# df = query |> list |> DataFrame

# query = M.Circuit |> object;
# query.values("circuitid", "name", "location", "country");
# query.order_by("circuitid");
# page(query, 10);

# df = query |> list |> DataFrame

# df.location = map(x -> ismissing(x) ? missing : uppercase(x), df.location)
# df.country = map(x -> ismissing(x) ? missing : uppercase(x), df.country)


# # bulk_update

# bulk_update(query, df)


