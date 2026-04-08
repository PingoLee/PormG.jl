# Database Configuration

PormG uses a flexible configuration system designed for Julia's asynchronous environment. Whether you are building a simple script or a complex multi-tenant server, PormG provides the tools to manage your database connections reliably.

## Core Concepts

### 1. Configuration Folders
In PormG, a **Configuration Folder** (like `db/` or `db_sch/`) is the unit of connection management. Each folder contains a `connection.yml` file that defines how to connect to the database.

- **Default Folder:** If you don't specify a path, PormG often looks for `db/`.
- **Multiple Databases:** You can have multiple folders (e.g., `db_primary`, `db_analytics`) to manage different connections in the same app.

### 2. Environments (`app_env`)
PormG supports multiple environments within the same `connection.yml`. Common values are `dev`, `test`, and `prod`. You can specify the environment globally via `ENV["PORMG_ENV"]` or explicitly in the `load` call.

### 3. Supported Adapters
- **PostgreSQL:** Primary adapter using `LibPQ.jl`. Supports high-performance async operations.
- **SQLite:** Fully supported via `SQLite.jl`. PormG uses a unique **Contextual Buckets Strategy** to enable complex joins and CTEs that are normally difficult in SQLite.

## Philosophy
The server application should keep:
- Mapping `AppConfig` to a set of database folders.
- Deciding whether a failed database should fail startup.
- Formatting HTTP health responses.

PormG should own:
- Loading and reloading database folders.
- Environment-aware configuration selection.
- Mapping folder paths to connection keys.
- Answering loaded-state and connectivity questions.
