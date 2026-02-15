# PormG Documentation

## Core Features

-   **Expressive Query Builder**: Django-inspired syntax using `filter`, `exclude`, `values`, `order_by`, and `annotate`.
-   **Model Management**: Define and manage database schemas with Julia structs and powerful field types.
-   **Multi-Database & Multi-Tenancy**: Built-in support for switching databases at runtime with lazy connection resolution via `.db("tenant_id")`.
-   **Async-First Execution**: Non-blocking database operations designed for high-concurrency web frameworks like Genie.jl.
-   **Cross-Database Support**: High-performance PostgreSQL integration (LibPQ) and lightweight SQLite support with automatic connection pooling.
-   **Migrations**: Automatic schema generation and evolution tool.
-   **Advisory Locks**: Safe coordination of concurrent processes using database-level distributed locks.

## Installation

PormG is currently in early development and is not yet registered in the Julia General Registry. To install the development version, you can use the Julia package manager with the GitHub repository URL.

Open the Julia REPL and run the following command:

```julia
using Pkg
Pkg.add(url="https://github.com/PingoLee/PormG.jl")
```

Alternatively, you can clone the repository and develop locally:

```julia
using Pkg
Pkg.develop(url="https://github.com/PingoLee/PormG.jl")
```

> **Note:** Since this is a development package, features may change and stability is not guaranteed. Please report any issues on the [GitHub repository](https://github.com/PingoLee/PormG.jl).

## Usage

Once installed, you can use PormG in your Julia projects by importing the module:

```julia
using PormG
```

### Quick Start

1. **Initialize your project:**
   ```julia
   using PormG
   PormG.setup() # Interactive setup for database and models
   ```

2. **Define your models:**
   Open `db/connection.yml` and configure your PostgreSQL connection:
   ```yaml
   env: dev

   dev:
     adapter: PostgreSQL
     database: your_database_name
     host: 'localhost'  # or your database host
     username: your_username
     password: your_password
     port: 5432  # default PostgreSQL port
     config:
       change_db: true # whether to create the database if it doesn't exist or modify it
       change_data: true # whether to modify existing data
       time_zone: 'America/Sao_Paulo'  # your timezone
   ```

3. **Create your models file:**
   Create `db/models.jl` with your model definitions:
   ```julia
   module models

   import PormG.Models

   User = Models.Model(
     id = Models.IDField(),
     name = Models.CharField(max_length=100),
     email = Models.EmailField(),
     age = Models.IntegerField()
   )

   # Add more models as needed...

   Models.set_models(@__MODULE__, @__DIR__)  # Required at end of file
   end
   ```

4. **Load configuration and connect:**
   ```julia
   PormG.Configuration.load("db")  # Load your connection settings
   ```

5. **Create and apply migrations:**
   ```julia
   PormG.Migrations.makemigrations("db")  # Analyze models and create migration
   PormG.Migrations.migrate("db")         # Apply migration to database
   ```

6. **Create some data:**
   ```julia
   # Include your models first
   include("db/models.jl")
   import .models as M

   # Create records using the create method
   user_query = M.User.objects
   user_query.create("name" => "Alice", "email" => "alice@example.com", "age" => 30)
   user_query.create("name" => "Bob", "email" => "bob@example.com", "age" => 25)
   user_query.create("name" => "Charlie", "email" => "charlie@example.com", "age" => 35)
   ```

7. **Query your data:**
   ```julia
   # Create and execute queries
   query = M.User.objects
   query.filter("name" => "Alice")
   results = query |> list
   ```

8. **Query your data with chainable methods:**
   ```julia
   results = M.User.objects.filter("age__gt" => 28).order_by("-age") |> list
   ```

For more detailed usage instructions and examples, please refer to the [API documentation](api.md).

## Database example
In addition to the basic user model, this documentation includes a comprehensive example of how to define models for a real-world racing database, based on the Formula 1 World Championship dataset (https://www.kaggle.com/datasets/rohanrao/formula-1-world-championship-1950-2020). This example demonstrates how to structure complex models, handle relationships, and apply PormG's ORM features to a production-scale schema. It serves as a practical reference for users who want to model more advanced databases beyond simple user tables.

## Contributing

Contributions to PormG are welcome! If you would like to contribute, please fork the repository and submit a pull request.

## License

PormG is licensed under the MIT License. See the LICENSE file for more details.