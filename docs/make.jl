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
        "Configuration" => "configuration.md",
        "Models" => "models.md",
        "Fields" => "fields.md",
        "Migrations" => "migrations.md",
        "Writing" => "write.md",
        "Reading" => "read.md",
        "API" => "api.md"
    ],
    format = Documenter.HTML(),
    checkdocs = :none, # Disable checkdocs to avoid unnecessary checks during documentation build
    
    # checkdocs = :exports,

)