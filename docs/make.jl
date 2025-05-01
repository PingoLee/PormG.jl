# This file is used to build the documentation for the PormG package.

using Documenter
using PormG

# Define the documentation directory
docs_dir = "docs/src"

# Build the documentation
makedocs(
    sitename = "PormG Documentation",
    modules = [PormG],
    pages = [
        "Home" => "index.md",
        "API" => "api.md"
    ],
    format = Documenter.HTML(),
    checkdocs = :none,
    # Additional options can be added here
)