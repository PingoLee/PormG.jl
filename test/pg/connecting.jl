# This file is a tutorial for the PormG connect at the PostgreSQL database.
using Pkg
Pkg.activate(".")

using Revise
using PormG

cd("test")
cd("pg")

PormG.Configuration.load("db_2")

# Error message when trying to load a non-existent database configuration.
# This error is triggered when the specified database configuration file (`"db_2\connection.yml"`)
# doesn't exist. In response, PormG.Configuration automatically creates a new 
# configuration file template for you to edit. After editing the configuration file,
# you should run the command again to successfully load the database configuration.

# Of course, you need create the database in PostgreSQL before running the command.

PormG.Configuration.load("db_2")

# If not error message is triggered, it means that the database configuration was successfully loaded.
# You can use how much database you want, just name a diferent name then "db_2".
# In folter "db_2" you can find the file "connection.yml" with the database configuration and a file with models from the database.