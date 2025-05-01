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
import PormG.QueryBuilder: Sum, Avg, Case, When, Count, Q, Qor, page, do_count, do_exists

# load models
Base.include(PormG, "db_2/models.jl")
import PormG.models as M


query = M.Status |> object;
query.filter("status" => "Engine");

query |> do_count

query |> do_exists

total, dict = query |> delete

# test fast delete
query = M.Just_a_test_deletion |> object;
query.filter("id" => 1);
query |> do_count
query |> do_exists
total, dict = query |> delete

# test delete all Just_a_test_deletion
query = M.Just_a_test_deletion |> object;
total, dict = delete(query; allow_delete_all = true)

# check if data is deleted
query = M.Just_a_test_deletion |> object;
query |> do_count

# test delete all Status
query = M.Status |> object;
total, dict = delete(query; allow_delete_all = true)

# test delete all Circuit
query = M.Circuit |> object;
query |> do_count
total, dict = delete(query; allow_delete_all = true)

# test delete all Driver
query = M.Driver |> object;
query |> do_count
total, dict = delete(query; allow_delete_all = true)

# test delete all Constructor
query = M.Constructor |> object;
query |> do_count
total, dict = delete(query; allow_delete_all = true)



# test delete

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