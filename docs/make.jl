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
        "Models" => "models.md",
        "Fields" => "fields.md",
        "Many-to-Many" => "many_to_many.md",
        "Configuration" => [
            "Overview" => "configuration/index.md",
            "Setup" => "configuration/setup.md",
            "Connection YML" => "configuration/connection_yml.md",
            "Server Patterns" => "configuration/server.md",
            "Dynamic & Multi-Tenancy" => "configuration/dynamic.md",
            "Advanced" => "configuration/advanced.md",
        ],        
        "Migrations" => [
            "Overview" => "migrations/index.md",
            "Workflow" => "migrations/workflow.md",
            "Advanced" => "migrations/advanced.md",
            # "Tachikoma Dashboard" => "migrations/tachikoma.md",
        ],
        "Writing" => [
            "Overview" => "write/index.md",
            "Creating Records" => "write/create.md",
            "Updating Records" => "write/update.md",
            "Deleting Records" => "write/delete.md",
            "Bulk Insert, Copy, and Update" => "write/bulk.md",
            "Transactions" => "write/transaction.md",
        ],
        "Reading" => [
            "Overview" => "read/index.md",
            "Values and Joins" => "read/values_and_joins.md",
            "Custom Joins" => "read/custom_joins.md",
            "Filters and Aggregates" => "read/filters_and_aggregates.md",
            "Functions and Dates" => "read/functions_and_dates.md",
            "Subqueries and CTEs" => "read/subqueries_and_ctes.md",
            "Field Expressions" => "read/field_expressions.md",
            "Window Functions" => "read/window_functions.md",
            "Q Objects" => "read/q_objects.md",
        ],
        "Import from Django" => "import_django.md",

        "Advisory Locks" => "advisory_lock.md",
        "Contributing" => "contributing.md",
        "API" => "api.md"
    ],
    
    format = Documenter.HTML(
        # prettyurls: Remove '.html' from the URL when running on GitHub (CI).
        # This creates clean links like ".../stable/configuration/"
        prettyurls = get(ENV, "CI", nothing) == "true",
        
        # Canonical: Defines the official URL for Google to avoid duplicate content
        canonical = "https://pingolee.github.io/PormG.jl",
        
        assets = String[],
        size_threshold = 400 * 1024, # 400 KiB
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