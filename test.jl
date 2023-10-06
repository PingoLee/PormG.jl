using Pkg
Pkg.activate(".")
include("src/PormG.jl")
using .PormG

PormG.Configuration.load()

a = object("teste")
a.values("a" , "b").filter("a" => 1, "b" => 2)

a.query()