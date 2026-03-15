using Documenter
using PormG
using Dates
using TimeZones

DocMeta.setdocmeta!(PormG, :DocTestSetup, :(using PormG, Dates, TimeZones), recursive=true)

# Build the documentation
makedocs(
    sitename = "PormG.jl: Django-like ORM for Julia",
    
    modules = [PormG, PormG.QueryBuilder, PormG.Models],
    source = "src",
    build = "build",
    
    pages = [
        "Home" => "index.md",
        "Configuration" => "configuration.md",
        "Models" => "models.md",
        "Fields" => "fields.md",
        "Migrations" => "migrations.md",
        "Writing" => [
            "Overview" => "write/index.md",
            "Creating Records" => "write/create.md",
            "Updating Records" => "write/update.md",
            "Deleting Records" => "write/delete.md",
            "Bulk Operations" => "write/bulk.md",
            "Transactions" => "write/transaction.md",
        ],
        "Reading" => [
            "Overview" => "read/index.md",
            "Values and Joins" => "read/values_and_joins.md",
            "Filters and Aggregates" => "read/filters_and_aggregates.md",
            "Functions and Dates" => "read/functions_and_dates.md",
            "Subqueries and CTEs" => "read/subqueries_and_ctes.md",
            "Field Expressions" => "read/field_expressions.md",
            "Q Objects" => "read/q_objects.md",
        ],
        "Import from Django" => "import_django.md",
        "Custom Joins" => "custom_joins.md",
        "Passwords" => "passwords.md",
        "Advisory Locks" => "advisory_lock.md",
        "API" => "api.md"
    ],
    
    format = Documenter.HTML(
        # prettyurls: Remove '.html' from the URL when running on GitHub (CI).
        # This creates clean links like ".../stable/configuration/"
        prettyurls = get(ENV, "CI", nothing) == "true",
        
        # Canonical: Defines the official URL for Google to avoid duplicate content
        canonical = "https://pingolee.github.io/PormG.jl",
        
        assets = String[],
    ),
    checkdocs = :none,
)

# Deploydocs: Sets up automatic upload to the gh-pages branch
# This will create the /dev (for main) and /stable (for version tags) directories
if get(ENV, "DOCS_DEPLOY", "false") == "true"
    deploydocs(
        repo = "github.com/PingoLee/PormG.jl.git",
        devbranch = "main",
    )
end