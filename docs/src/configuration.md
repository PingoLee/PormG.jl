# Database Configuration in PormG

PormG uses a simple YAML-based configuration system to manage connections to your PostgreSQL databases. Each database connection is defined in a `connection.yml` file inside a dedicated folder (e.g., `db`, `db_2`).

## How Configuration Works

- By default, PormG looks for a folder named `db` containing a `connection.yml` file.
- You can use any folder name (e.g., `db_2`) to manage multiple databases. Each folder should have its own `connection.yml` and models file.

## Creating a Configuration

To set up a new database connection:

1. **Create a Folder**
   - Example: `db_2`
2. **Run the Configuration Loader**
   - If the configuration file does not exist, PormG will create a template for you:
     ```julia
     PormG.Configuration.load("db_2")
     ```
   - If `db_2/connection.yml` does not exist, a template will be generated. Edit this file with your PostgreSQL connection details.
3. **Edit the Configuration File**
   - Open `db_2/connection.yml` and fill in your database host, port, user, password, and database name.
4. **Create the Database**
   - Make sure the database exists in PostgreSQL before loading the configuration.
5. **Load the Configuration**
   - Run the loader again to connect:
     ```julia
     PormG.Configuration.load("db_2")
     ```
   - If no error is triggered, the configuration was loaded successfully.

## Example: Configuration Script

```julia
using Pkg
Pkg.activate(".")
using PormG
PormG.Configuration.load("db_2")
```

## Notes
- You can manage as many databases as you want by using different folders and configuration files.
- The folder will also contain your models and migration files for that database.
- If you try to load a configuration that does not exist, PormG will help you by creating a template.

---
For more details, see the [PormG Documentation](index.md) or the example scripts in the `test/pg/` folder.
