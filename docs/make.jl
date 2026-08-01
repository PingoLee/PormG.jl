using Documenter
using DocumenterMermaid
using PormG
using Dates
using TimeZones

DocMeta.setdocmeta!(PormG, :DocTestSetup, :(using PormG, Dates, TimeZones), recursive=true)

# Build the documentation
makedocs(
    sitename = "PormG.jl: Django-like ORM for Julia",
    
    modules = [
        PormG,
        PormG.Kernel,
        PormG.Functions,
        PormG.QueryBuilder,
        PormG.Models,
        PormG.Migrations,
        PormG.Configuration,
        PormG.ConnectionPool,
        PormG.Utils,
    ],
    source = "src",
    build = "build",
    
    pages = [
        "Home" => "index.md",
        "Data Modeling" => [
            "Models" => "models.md",
            "Fields" => "fields.md",
            "Schema Conventions" => "schema_conventions.md",
            "Many-to-Many" => "many_to_many.md",
        ],
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
            "Format Stability" => "migrations/stability.md",
            "Advanced" => "migrations/advanced.md",
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
        "Guides" => [
            "Error Handling" => "errors.md",
            "PostgreSQL Guide" => "postgres.md",
            "Async & Concurrency" => "async.md",
            "Advisory Locks" => "advisory_lock.md",
            "Import from Django" => "import_django.md",
            "Upgrading PormG" => "upgrading.md",
        ],
        "Internals" => [
            "Architecture" => "architecture.md",
            "Extending PormG" => "extending.md",
            "Contributing" => "contributing.md",
        ],
        "API" => "api.md"
    ],
    
    format = Documenter.HTML(
        # prettyurls: Remove '.html' from the URL when running on GitHub (CI).
        # This creates clean links like ".../stable/configuration/"
        prettyurls = get(ENV, "CI", nothing) == "true",
        
        # Canonical: Defines the official URL for Google to avoid duplicate content
        canonical = "https://pingolee.github.io/PormG.jl",
        
        # collapselevel = 1: every top-level section (Configuration, Migrations, Reading, ...)
        # renders as a collapsed, chevron-toggled group instead of dumping all ~30 child pages
        # into the sidebar at once. Documenter auto-expands the section containing the current
        # page, so navigation stays one click deep.
        collapselevel = 1,

        assets = String[],
        # api.md is one comprehensive page: hand-written reference plus an @autodocs dump of every
        # module. It renders to ~510 KiB as of #274 (measured, not estimated — the previous "~340
        # KiB" note dated from before #212/#213/#274 added ~45 docstrings). Raised 600 → 900 KiB so
        # the next batch of docstrings does not fail the build; re-measure `docs/build/api.html`
        # and update this number whenever a PR adds a significant number of docstrings.
        size_threshold = 900 * 1024,
        # Documenter warns at 100 KiB by default, which api.md passed long ago and will never go
        # back under — so that warning was pure noise. Move the warn limit to 700 KiB: below the
        # 900 KiB hard limit, but above today's 510 KiB, so it fires as an early signal that the
        # page is approaching the ceiling instead of on every single build.
        size_threshold_warn = 700 * 1024,
    ),
    checkdocs = :exports,
)

# Deploydocs: Sets up automatic upload to the gh-pages branch
# This will create the /dev (for main) and /stable (for version tags) directories
if get(ENV, "DOCS_DEPLOY", "false") == "true"
    deploydocs(
        repo = "github.com/PingoLee/PormG.jl.git",
        devbranch = "main",
    )
end