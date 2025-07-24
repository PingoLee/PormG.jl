# This file is used to build the documentation for the PormG package.

using Documenter
using PormG

# Define the documentation directory
docs_dir = "docs/src"

# Build the documentation
makedocs(
    sitename = "PormG Documentation",
    modules = [PormG, PormG.QueryBuilder, PormG.Models],
    pages = [
        "Home" => "index.md",
        "Migrations" => "migrations.md",
        "Models" => "models.md",
        "Search queries" => "queries.md",
        "Function queries" => "function.md",
        "Whrite queries" => "write.md",
        "API" => "api.md"
    ],
    format = Documenter.HTML(),
    checkdocs = :none, # Disable checkdocs to avoid unnecessary checks during documentation build
    
    # checkdocs = :exports,

)