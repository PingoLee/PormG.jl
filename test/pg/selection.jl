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


# select all results with status = 5
query = M.Status |> object;
query.filter("status" => "Engine");
query |> do_count
query |> do_exists
df = query |> list |> DataFrame

query = M.Result |> object;
query.filter("statusid__status" => "Engine");
query |> do_count
query.values("resultid", "statusid", "statusid__status");

df = query |> list |> DataFrame