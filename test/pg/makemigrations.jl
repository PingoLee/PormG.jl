# This script is used to create the database and tables for the PormG package.
using Pkg
Pkg.activate(".")

using Revise
using PormG
using DataFrames

cd("test")
cd("pg")

PormG.Configuration.load("db_2")

# This script is used to create the database and tables using db_2\models.jl as instructions.
# The models.jl file is manually created and contains the instructions for creating the database to https://www.kaggle.com/datasets/rohanrao/formula-1-world-championship-1950-2020, the .csv files are in the folder "f1"


PormG.Migrations.makemigrations("db_2")

#=
## PormG Migration Tutorial

PormG provides a simple way to manage database schema changes through migrations.

### Understanding the Process:

1. First, you define your models in the `db_2/models.jl` file
2. Then you run `makemigrations` to generate migration files
3. Review the generated migrations in `db_2/migrations/pending_migrations.jl`
4. Finally, apply the migrations with `migrate`

### Common Workflow:

- When you need to update your database schema, modify your models
- Run makemigrations again to create incremental changes
- Review and apply the new migrations

The warning above tells you that migrations were generated but not yet applied.
You should always review the migration plan before applying it to production databases.
=#

PormG.Migrations.migrate("db_2")

# If not error message is triggered, it means that the database was successfully created.
# Now, a new folder "applied_migrations" is created with the migrations that were applied to the database.

# At this stage, PormG is quite different from Django. PormG operates by converting a PostgreSQL database into its own model, comparing this against the models.jl file, and subsequently generating a migration plan for PostgreSQL.
