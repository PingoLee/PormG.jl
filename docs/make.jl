# This file is used to build the documentation for the PormG package.

using Documenter
using PormG

# Build the documentation
makedocs(
    sitename = "PormG Documentation",
    modules = [PormG, PormG.QueryBuilder, PormG.Models],
    source = "src",
    build = "build",
    pages = [
        "Home" => "index.md",
        "Configuration" => "configuration.md",
        "Models" => "models.md",
        "Fields" => "fields.md",
        "Migrations" => "migrations.md",
        "Writing" => "write.md",
        "Reading" => "read.md",
        "Import from Django" => "import_django.md",
        "Custom Joins" => "custom_joins.md",
        "API" => "api.md"
    ],
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true",
        canonical = "https://pingolee.github.io/PormG.jl",
        assets = String[],
    ),
    checkdocs = :none,
)