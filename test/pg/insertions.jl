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
import PormG.QueryBuilder: Sum, Avg, Case, When, Count, Q, Qor, F, page # Important: to import this to use the functions in the query

# First load the models
Base.include(PormG, "db_2/models.jl")
import PormG.models as M


# If you already have a database and want clear all data in the tables, open clear_all.jl and run it.

# Now you can use the models to insert data in the database one by one
path_load = joinpath("f1", "status.csv")
df = CSV.File(path_load) |> DataFrame

query = M.Status |> object;
query |> do_count
for row in eachrow(df)
    dt = query.create("statusid" => row.statusId, "status" => row.status)
    println(row.statusId)
end

# Now you can use bulk_insert to insert data in the database in bulk
query = M.Circuit |> object;
query |> do_count
path_load = joinpath("f1", "circuits.csv")
df = CSV.File(path_load) |> DataFrame
bulk_insert(query, df, show_query=true)


query = M.Race |> object;
path_load = joinpath("f1", "races.csv")
df = CSV.File(path_load) |> DataFrame
rename!(df, lowercase.(names(df)))
bulk_insert(query, df) # a error is expected
# ArgumentError: Error in bulk_insert, the field fp1_date in row 1 has a value that can't be formatted: \N

# pre-processing
rename!(df, lowercase.(names(df)))
for col in [:fp1_date, :fp1_time, :fp2_date, :fp2_time, :fp3_date, :fp3_time, :quali_date, :quali_time, :sprint_date, :sprint_time, :time]
    df[!, col] = map(x -> ismissing(x) || x == "\\N" ? missing : x, df[!, col])
end

bulk_insert(query, df, copy=true) # now it should work

query = M.Driver |> object;
# query |> do_count
df = CSV.File(joinpath("f1", "drivers.csv")) |> DataFrame
for col in [:number]
    df[!, col] = map(x -> ismissing(x) || x == "\\N" ? missing : x, df[!, col])
end
bulk_insert(query, df)

query = M.Constructor |> object;
# query |> do_count
df = CSV.File(joinpath("f1", "constructors.csv")) |> DataFrame
bulk_insert(query, df)

query = M.Result |> object;
df = CSV.File(joinpath("f1", "results.csv")) |> DataFrame
# lowercase the column names
rename!(df, lowercase.(names(df)))
for col in [:position, :time, :milliseconds, :fastestlap, :rank, :fastestlaptime, :fastestlapspeed, :number]
    df[!, col] = map(x -> ismissing(x) || x == "\\N" ? missing : x, df[!, col])
end
bulk_insert(query, df)


# Deal with updates
query = M.Just_a_test_deletion |> object;
query |> do_count && delete(query; allow_delete_all = true)
query.create("name" => "test", "test_result" => 1)
query.create("name" => "test", "test_result" => 2)
query.create("name" => "test", "test_result" => 3)

# update the single data
query = M.Just_a_test_deletion |> object;
query.filter("test_result" => 1);
query.update("name" => "test_update")

query = M.Just_a_test_deletion |> object;
df = query |> list |> DataFrame

# update the bulk data from df
query = M.Just_a_test_deletion |> object;
for (index, row) in eachrow(df) |> enumerate
  row.name = "test_update_$(index)"
end
bulk_update(query, df, columns=["name"], filters=["id"], show_query=true)
query = M.Just_a_test_deletion |> object;
df = query |> list |> DataFrame

# Teste F expressions
query = M.Just_a_test_deletion |> object;
query.filter("test_result" => 1);
query.update("test_result2" => F("test_result")) # update a value with a F expression
query2 = M.Just_a_test_deletion |> object;
df = query2 |> list |> DataFrame

query.update("test_result2" => F("test_result") + 1);
df = query2 |> list |> DataFrame

query.update("test_result2" => F("test_result2") * 2);
df = query2 |> list |> DataFrame

query.update("test_result2" => F("test_result2") / 2);
df = query2 |> list |> DataFrame

query.update("test_result2" => F("test_result") + F("test_result"));
df = query2 |> list |> DataFrame

query.update("test_result2" => F("test_result2") - 1);
df = query2 |> list |> DataFrame

query.update("test_result2" => missing);
df = query2 |> list |> DataFrame

# Teste F expressions with join
# i know this examples does not make much sense, but it is just to test the F expressions with joins
query = M.Just_a_test_deletion |> object;
query.filter("test_result" => 1);
query.update("test_result2" => F("test_result__statusid") );
df = query2 |> list |> DataFrame


query = M.Just_a_test_deletion |> object;
query.filter("test_result" => 1);
query.update("test_result2" => F("test_result__driverid__number") );
df = query2 |> list |> DataFrame
