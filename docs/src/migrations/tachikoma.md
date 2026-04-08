# Terminal Dashboard (Tachikoma)

PormG includes an optional interactive dashboard built on top of **Tachikoma.jl**. It's designed for local development and debugging when you want to review and apply migrations or inspect generated SQL through a terminal interface.

## Requirements

The dashboard is provided by the `PormGTachikomaExt` package extension. To use it, you must have `Tachikoma.jl` installed and loaded:

```julia
using PormG
using Tachikoma
```

If Tachikoma is not loaded, `PormG.tui()` will throw an informative error.

### Linux, macOS, and WSL Only
Currently, the terminal app loop depends on Unix-style file descriptor operations. **Native Windows is not supported at this time.** Please use **WSL (Windows Subsystem for Linux)** if you are developing on a Windows machine.

---

## Launching the Dashboard

To launch the dashboard, pass the path of your database configuration folder:

```julia
# Optional: Load your models for query inspection
PormG.@import_models "db/models.jl" models
import .models as M

# Launch TUI
PormG.tui("db"; models_module=M)
```

---

## Dashboard Panes

### 1. Migrations Pane
Interact with the database migration engine through:
- **Status:** View applied and pending migrations.
- **Dry-run:** Review SQL for pending migrations without applying.
- **Init:** Bootstrap the `pormg_migrations` history table.
- **Migrate:** Apply the current `pending_migrations.jl` file.

### 2. Inspection Pane
Debug your fluent queries by viewing:
- **Generated SQL:** See the exact SQL text with placeholders.
- **Parameters:** Inspect the list of parameterized values.
- **Dialect Info:** View dialect-specific rendering details.
- **Context Buckets:** For SQLite, view the contextual buckets used for joins and CTEs.

---

## Recommended Workflow

The intended workflow for using the dashboard:

1.  **Generate Plan:** `PormG.Migrations.makemigrations("db")`
2.  **Launch TUI:** `PormG.tui("db")`
3.  **Review:** Use the **Migrations Pane** to run `dry_run` and inspect the SQL.
4.  **Apply:** Use the **Migrate** action to complete the process.
