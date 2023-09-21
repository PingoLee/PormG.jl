module PormG

import DataFrames, OrderedCollections, Distributed, Dates, Logging, Millboard, YAML
import DataFrames.DataFrame

include("constants.jl")

haskey(ENV, "PORMG_ENV") || (ENV["PORMG_ENV"] = "dev")

# include("Exceptions.jl") to do 

import Inflector

include("Configuration.jl")
using .Configuration

const config =  PormG.Configuration.Settings(app_env = ENV["PORMG_ENV"])

end # module PormG
