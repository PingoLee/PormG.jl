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
query = M.Just_a_test_deletion |> object
query.filter("id" => 1)
query |> do_count
query |> do_exists
total, dict = query |> delete
