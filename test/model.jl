using Pkg
Pkg.activate(".")
# Pkg.instantiate()
using Revise
# include("src/PormG.jl")
using PormG

PormG.Configuration.load()


import PormG: Models

users = Models.Model("users", 
  name = Models.CharField(), 
  email = Models.CharField(), 
  age = Models.IntegerField()
)

cars = Models.Model("cars", 
  user = Models.ForeignKey(users, "CASCADE"),
  name = Models.CharField(), 
  brand = Models.CharField(), 
  year = Models.IntegerField()
)

Models.Model("users")

Models.Model()


query = object(users)



