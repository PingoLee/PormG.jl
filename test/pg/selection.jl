using Pkg
Pkg.activate(".")

using Revise
# using Infiltrator
using PormG
using DataFrames
using CSV

cd("test")
cd("pg")

# PormG.Configuration.load()
PormG.Configuration.load("db_2")

# teste compation of fields
import PormG.QueryBuilder: Sum, Avg, Case, When, Count, Q, Qor, page, do_count, do_exists, show_query, Max, Min

# load models
Base.include(PormG, "db_2/models.jl")
import PormG.models as M


# select all results with status = 5 (Engine)
query = M.Status |> object;
query.filter("status" => "Engine");

count = query |> do_count
exists = query |> do_exists
df = query |> list |> DataFrame


# Now, select all status = 5 (Engine) in Result table
query = M.Result |> object;
query.filter("statusid__status" => "Engine");

# count how many results with statusid = 5 (Engine)
query |> do_count

# report the selection in a df
query.values("resultid", "statusid", "statusid__status");
df = query |> list |> DataFrame # get the result in a df
@info query |> show_query # show the query

# If you want keep the same filters but change the values to be selected, you can do it like this:
query.values("resultid", "driverid__forename", "constructorid__name", "statusid__status", "grid", "laps");
df = query |> list |> DataFrame # get the result in a df
@info query |> show_query # show the query

# if you want keep the filters and user postgresql functions, you can do it like this:
query.values("raceid__circuitid__name", "driverid__forename", "constructorid__name", "count_grid" => Count("grid"), "max_grid" => Max("grid"), "min_grid" => Min("grid"));
query.order_by("raceid__circuitid__name");
df = query |> list |> DataFrame # get the result in a df
@info query |> show_query # show the query

# If i want add a filter to the query, i can do it like this:
query.filter("driverid__forename" => "Ayrton");
df = query |> list |> DataFrame # get the result in a df
@info query |> show_query # show the query

# Hoewver, once i add a filter, doesn't exist a way to remove it. So, if i want remove it, i need to create a new query.
query = M.Result |> object;
query.filter("statusid__status" => "Finished", "driverid__forename" => "Ayrton");
query.values("raceid__circuitid__name", "driverid__forename", "constructorid__name", "count_grid" => Count("grid"), "max_grid" => Max("grid"), "min_grid" => Min("grid"));
query.order_by("raceid__circuitid__name");
df = query |> list |> DataFrame # get the result in a df
@info query |> show_query # show the query

# if you want add a filter with a function, you can do it like this:
query.filter("raceid__circuitid__name__@contains" => "Monaco");
df = query |> list |> DataFrame # get the result in a df

# Test now case sesivity
query = M.Result |> object;
query.filter("raceid__circuitid__name__@contains" => "monaco");
query |> do_count

query = M.Result |> object;
query.filter("raceid__circuitid__name__@icontains" => "monaco");
query |> do_count

# Dealing with Dates
query = M.Race |> object;
query.filter("date__@year" => 1991);
query.values("date__@year", "date__@month", "date__@day", "rows" => Count("raceid"));
df = query |> list |> DataFrame # get the result in a df

query.values("date__@yyyy_mm", "rows" => Count("raceid"));
df = query |> list |> DataFrame # get the result in a df

query.values("date__@quarter", "rows" => Count("raceid"));
df = query |> list |> DataFrame # get the result in a df




@time begin
    query = M.Result |> object;
    query.filter("statusid__status" => "Finished", "driverid__forename" => "Ayrton");
    query.values("raceid__circuitid__name", "driverid__forename", "constructorid__name", "count_grid" => Count("grid"), "max_grid" => Max("grid"), "min_grid" => Min("grid"));
    query.order_by("raceid__circuitid__name");
    query |> show_query
end

#