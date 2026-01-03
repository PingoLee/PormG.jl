using Documenter
using PormG

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
        "Writing" => "write.md",
        "Transactions" => "transaction.md",
        "Reading" => "read.md",
        "Import from Django" => "import_django.md",
        "Custom Joins" => "custom_joins.md",
        "API" => "api.md"
    ],
    
    format = Documenter.HTML(
        # prettyurls: Remove '.html' da URL quando rodando no GitHub (CI).
        # Isso cria links limpos como ".../stable/configuration/"
        prettyurls = get(ENV, "CI", nothing) == "true",
        
        # Canonical: Define a URL oficial para o Google evitar conteúdo duplicado
        canonical = "https://pingolee.github.io/PormG.jl",
        
        assets = String[],
    ),
    checkdocs = :none,
)

# Deploydocs: Configura o upload automático para a branch gh-pages
# Isso vai criar as pastas /dev (para main) e /stable (para tags de versão)
if get(ENV, "DOCS_DEPLOY", "false") == "true"
    deploydocs(
        repo = "github.com/PingoLee/PormG.jl.git",
        devbranch = "main",
    )
end