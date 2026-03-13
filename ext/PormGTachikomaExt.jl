# ==============================================================================
# PormGTachikomaExt — Terminal UI extension for PormG
# Provides interactive Migrations and Query Inspection panes via Tachikoma.jl
# ==============================================================================

module PormGTachikomaExt

using PormG
import Tachikoma
import Tachikoma: Model, Frame, KeyEvent, Event, TaskEvent, TaskQueue,
                  Block, Paragraph, StatusBar, Span, DataTable, ScrollPane,
                  Layout, Vertical, Horizontal, Fixed, Fill,
                  tstyle, render, split_layout, set_string!, bottom, Rect,
                  app, spawn_task!

using Tachikoma: @tachikoma_app

# Re-import PormG.Migrations for calling status/dry_run/migrate
import PormG.Migrations: status, dry_run, init_migrations, makemigrations, migrate,
                         MigrationStatus, DryRunResult

# -- Pane enum --
@enum ActivePane MigrationsPane InspectionPane

# ==========================================================================
# App Model
# ==========================================================================
@kwdef mutable struct PormGDashboard <: Model
  quit::Bool = false
  tick::Int = 0
  tq::TaskQueue = TaskQueue()

  # --- Navigation ---
  active_pane::ActivePane = MigrationsPane

  # --- Migrations state ---
  db_path::String = ""
  mig_status::Union{Nothing, MigrationStatus} = nothing
  mig_dry_run::Union{Nothing, DryRunResult} = nothing
  mig_log::Vector{String} = ["Press [s] to load migration status"]
  mig_error::String = ""
  mig_scroll::Int = 0  # scroll offset for SQL statements

  # --- Inspection state ---
  models_module::Union{Nothing, Module} = nothing  # User's models module
  available_models::Vector{Pair{Symbol, Any}} = []  # (name => model) pairs
  insp_filter_text::String = ""
  insp_result::Union{Nothing, Dict} = nothing
  insp_log::Vector{String} = ["Type a model name and press [Enter] to inspect"]
  insp_error::String = ""
end

Tachikoma.should_quit(m::PormGDashboard) = m.quit
Tachikoma.task_queue(m::PormGDashboard) = m.tq

# ==========================================================================
# Event Handling
# ==========================================================================

function Tachikoma.update!(m::PormGDashboard, evt::KeyEvent)
  # Global keys
  if evt.key == :escape
    m.quit = true
    return
  end

  # Tab switching: Ctrl+1 / Ctrl+2 or F1/F2
  if evt.key == :f1
    m.active_pane = MigrationsPane
    return
  elseif evt.key == :f2
    m.active_pane = InspectionPane
    return
  end

  # Delegate to active pane
  if m.active_pane == MigrationsPane
    _update_migrations!(m, evt)
  else
    _update_inspection!(m, evt)
  end
end

function Tachikoma.update!(m::PormGDashboard, evt::TaskEvent)
  if evt.id == :mig_status
    if evt.value isa Exception
      m.mig_error = string(evt.value)
      push!(m.mig_log, "Error loading status: $(m.mig_error)")
    else
      m.mig_status = evt.value
      m.mig_error = ""
      push!(m.mig_log, "Status loaded successfully")
    end
  elseif evt.id == :mig_dry_run
    if evt.value isa Exception
      m.mig_error = string(evt.value)
      push!(m.mig_log, "Error running dry_run: $(m.mig_error)")
    else
      m.mig_dry_run = evt.value
      m.mig_error = ""
      push!(m.mig_log, "Dry run completed — $(evt.value.total_statements) statement(s)")
    end
  elseif evt.id == :mig_init
    if evt.value isa Exception
      m.mig_error = string(evt.value)
      push!(m.mig_log, "Error: $(m.mig_error)")
    else
      push!(m.mig_log, "init_migrations completed")
    end
  elseif evt.id == :mig_migrate
    if evt.value isa Exception
      m.mig_error = string(evt.value)
      push!(m.mig_log, "Migration failed: $(m.mig_error)")
    else
      push!(m.mig_log, "Migration applied successfully")
      # Auto-refresh status
      _spawn_status!(m)
    end
  elseif evt.id == :insp_query
    if evt.value isa Exception
      m.insp_error = string(evt.value)
      push!(m.insp_log, "Inspection error: $(m.insp_error)")
    else
      m.insp_result = evt.value
      m.insp_error = ""
      push!(m.insp_log, "Query inspected: $(evt.value[:operation])")
    end
  end
end

# ---------- Migrations input ----------

function _update_migrations!(m::PormGDashboard, evt::KeyEvent)
  if evt.key == :char
    c = evt.char
    if c == 's'
      # Load status
      _spawn_status!(m)
    elseif c == 'd'
      # Dry run
      _spawn_dry_run!(m)
    elseif c == 'i'
      # Init migrations
      _spawn_init!(m)
    elseif c == 'm'
      # Migrate (safe only — no destructive without explicit flag)
      _spawn_migrate!(m)
    elseif c == 'j'
      m.mig_scroll = min(m.mig_scroll + 1, _max_scroll(m))
    elseif c == 'k'
      m.mig_scroll = max(m.mig_scroll - 1, 0)
    end
  elseif evt.key == :down
    m.mig_scroll = min(m.mig_scroll + 1, _max_scroll(m))
  elseif evt.key == :up
    m.mig_scroll = max(m.mig_scroll - 1, 0)
  end
end

function _max_scroll(m::PormGDashboard)
  m.mig_dry_run === nothing && return 0
  return max(0, length(m.mig_dry_run.statements) - 5)
end

# ---------- Inspection input ----------

function _update_inspection!(m::PormGDashboard, evt::KeyEvent)
  if evt.key == :char
    m.insp_filter_text *= evt.char
  elseif evt.key == :backspace
    if !isempty(m.insp_filter_text)
      m.insp_filter_text = m.insp_filter_text[1:prevind(m.insp_filter_text, end)]
    end
  elseif evt.key == :enter
    _run_inspection!(m)
  end
end

# ==========================================================================
# Background Tasks
# ==========================================================================

function _spawn_status!(m::PormGDashboard)
  db = m.db_path
  push!(m.mig_log, "Loading migration status...")
  spawn_task!(m.tq, :mig_status) do
    status(db)
  end
end

function _spawn_dry_run!(m::PormGDashboard)
  db = m.db_path
  push!(m.mig_log, "Running dry_run...")
  spawn_task!(m.tq, :mig_dry_run) do
    dry_run(db)
  end
end

function _spawn_init!(m::PormGDashboard)
  db = m.db_path
  push!(m.mig_log, "Initializing migrations table...")
  spawn_task!(m.tq, :mig_init) do
    init_migrations(db)
    "ok"
  end
end

function _spawn_migrate!(m::PormGDashboard)
  db = m.db_path
  push!(m.mig_log, "Applying pending migrations (safe only)...")
  spawn_task!(m.tq, :mig_migrate) do
    migrate(db; interactive=false, destructive=false)
    "ok"
  end
end

function _run_inspection!(m::PormGDashboard)
  text = strip(m.insp_filter_text)
  isempty(text) && return
  push!(m.insp_log, "Inspecting: $text")

  if m.models_module === nothing
    m.insp_error = "No models module provided. Pass models_module to tui()."
    return
  end

  # Build available_models on first use
  if isempty(m.available_models)
    _load_available_models!(m)
  end

  # Capture references for the task closure
  avail = m.available_models

  spawn_task!(m.tq, :insp_query) do
    # Parse input: "ModelName" or "ModelName key=value key2=value2"
    parts = split(text, " ", limit=2)
    model_name = parts[1]
    model_sym = Symbol(model_name)

    # Find the model in available_models
    idx = findfirst(p -> p.first == model_sym, avail)
    if idx === nothing
      available_names = join([string(p.first) for p in avail], ", ")
      error("Model '$model_name' not found. Available: $available_names")
    end
    model_obj = avail[idx].second

    # Build query via the object API
    q = PormG.object(model_obj)

    # Apply filters if provided: "key=value key2=value2"
    if length(parts) > 1
      filter_str = parts[2]
      for pair in split(filter_str, " ")
        kv = split(pair, "=", limit=2)
        length(kv) == 2 || continue
        q.filter(String(kv[1]) => String(kv[2]))
      end
    end

    q.limit!(10)
    PormG.inspect_query(q)
  end
end

function _load_available_models!(m::PormGDashboard)
  mod = m.models_module
  mod === nothing && return
  empty!(m.available_models)
  for name in names(mod; all=true, imported=true)
    attr = try
      Base.invokelatest(getfield, mod, name)
    catch
      nothing
    end
    if attr isa PormG.PormGModel
      push!(m.available_models, name => attr)
    end
  end
  sort!(m.available_models, by=p -> string(p.first))
end

# ==========================================================================
# Rendering
# ==========================================================================

function Tachikoma.view(m::PormGDashboard, f::Frame)
  m.tick += 1
  buf = f.buffer

  # Top-level layout: header (1 row) + body (fill) + status bar (1 row)
  rows = split_layout(Layout(Vertical, [Fixed(1), Fill(), Fixed(1)]), f.area)
  length(rows) < 3 && return

  # --- Header: tab bar ---
  _render_tabs!(m, rows[1], buf)

  # --- Body ---
  if m.active_pane == MigrationsPane
    _render_migrations!(m, rows[2], buf)
  else
    _render_inspection!(m, rows[2], buf)
  end

  # --- Status bar ---
  active = m.tq.active[]
  task_label = active > 0 ? "$(active) task(s) running" : "idle"
  task_style = active > 0 ? tstyle(:accent) : tstyle(:text_dim)
  render(StatusBar(
    left=[Span("  [F1] Migrations  [F2] Inspection  [Esc] Quit ", tstyle(:text_dim))],
    right=[Span(task_label * " ", task_style)],
  ), rows[3], buf)
end

# ---------- Tab bar ----------

function _render_tabs!(m::PormGDashboard, area::Rect, buf)
  mig_style = m.active_pane == MigrationsPane ? tstyle(:accent, bold=true) : tstyle(:text_dim)
  insp_style = m.active_pane == InspectionPane ? tstyle(:accent, bold=true) : tstyle(:text_dim)

  set_string!(buf, area.x + 1, area.y, " Migrations ", mig_style)
  set_string!(buf, area.x + 14, area.y, " │ ", tstyle(:border))
  set_string!(buf, area.x + 17, area.y, " Inspection ", insp_style)
end

# ---------- Migrations pane ----------

function _render_migrations!(m::PormGDashboard, area::Rect, buf)
  # Split: left = status panel, right = dry run / SQL preview
  cols = split_layout(Layout(Horizontal, [Fill(), Fill()]), area)
  length(cols) < 2 && return

  _render_mig_status!(m, cols[1], buf)
  _render_mig_dry_run!(m, cols[2], buf)
end

function _render_mig_status!(m::PormGDashboard, area::Rect, buf)
  inner = render(Block(title="Migration Status  [s]refresh [i]init [m]migrate"), area, buf)

  lines = String[]
  if m.mig_status === nothing
    push!(lines, "No status loaded yet.")
    push!(lines, "")
    push!(lines, "Press [s] to load migration status.")
  else
    s = m.mig_status
    push!(lines, "History table: " * (s.has_history_table ? "✓ exists" : "✗ not initialized"))
    push!(lines, "Applied: $(length(s.applied)) migration(s)")

    if !isempty(s.failed)
      push!(lines, "")
      push!(lines, "FAILED: $(length(s.failed)) migration(s)")
      for mig in s.failed
        push!(lines, "  - v$(mig[:version]) $(mig[:name])")
      end
    end

    push!(lines, "Pending file: " * (s.pending ? "yes" : "none"))

    if !isempty(s.drift_signals)
      push!(lines, "")
      push!(lines, "Drift signals:")
      for d in s.drift_signals
        push!(lines, "  ⚠ $d")
      end
    end

    if !isempty(s.applied)
      push!(lines, "")
      push!(lines, "Applied migrations:")
      for mig in s.applied
        destr = mig[:is_destructive] in [true, 1] ? "destructive" : "safe"
        push!(lines, "  [$(mig[:version])] $(mig[:name]) ($(mig[:status]), $destr)")
      end
    end
  end

  if !isempty(m.mig_error)
    push!(lines, "")
    push!(lines, "Error: $(m.mig_error)")
  end

  # Render log underneath
  push!(lines, "")
  push!(lines, "── Log ──")
  # Show last N log entries that fit
  max_log = max(1, inner.height - length(lines) - 1)
  log_slice = m.mig_log[max(1, end - max_log + 1):end]
  append!(lines, log_slice)

  render(ScrollPane(lines; following=true), inner, buf)
end

function _render_mig_dry_run!(m::PormGDashboard, area::Rect, buf)
  inner = render(Block(title="Dry Run Preview  [d]run  [j/k]scroll"), area, buf)

  lines = String[]
  if m.mig_dry_run === nothing
    push!(lines, "No dry run loaded.")
    push!(lines, "")
    push!(lines, "Press [d] to run dry_run().")
  else
    dr = m.mig_dry_run
    push!(lines, "Checksum: $(dr.checksum[1:min(16, length(dr.checksum))])...")
    push!(lines, "Statements: $(Migrations.total_statements(dr))")

    if Migrations.is_destructive(dr)
      push!(lines, "")
      push!(lines, "⚠ DESTRUCTIVE: $(length(dr.destructive_statements)) statement(s)")
      for s in dr.destructive_statements
        display_s = length(s) > 80 ? s[1:80] * "..." : s
        push!(lines, "  → $display_s")
      end
    else
      push!(lines, "✓ Safe (no destructive operations)")
    end

    push!(lines, "")
    push!(lines, "── SQL Statements ──")

    # Apply scroll offset
    stmts = dr.statements
    start_idx = m.mig_scroll + 1
    for (i, s) in enumerate(stmts)
      i < start_idx && continue
      # Number each statement
      for line in split(s, "\n")
        push!(lines, "  $i. $line")
      end
      push!(lines, "")
    end
  end

  render(ScrollPane(lines; following=false), inner, buf)
end

# ---------- Inspection pane ----------

function _render_inspection!(m::PormGDashboard, area::Rect, buf)
  # Split: top = input area, bottom = result
  rows = split_layout(Layout(Vertical, [Fixed(5), Fill()]), area)
  length(rows) < 2 && return

  _render_insp_input!(m, rows[1], buf)
  _render_insp_result!(m, rows[2], buf)
end

function _render_insp_input!(m::PormGDashboard, area::Rect, buf)
  inner = render(Block(title="Query Inspector — type: ModelName key=val key2=val2 [Enter]"), area, buf)

  # Input line with cursor
  prompt = "> "
  cursor_char = m.tick % 20 < 10 ? "█" : " "
  input_display = prompt * m.insp_filter_text * cursor_char

  set_string!(buf, inner.x, inner.y, input_display, tstyle(:primary, bold=true))

  # Hint text
  if isempty(m.insp_filter_text)
    set_string!(buf, inner.x, inner.y + 1, "  e.g.: Result driverid__forename=Lewis positionorder=1", tstyle(:text_dim))
    if !isempty(m.available_models)
      model_names = join([string(p.first) for p in m.available_models[1:min(8, end)]], ", ")
      suffix = length(m.available_models) > 8 ? ", ..." : ""
      set_string!(buf, inner.x, inner.y + 2, "  Models: $model_names$suffix", tstyle(:text_dim))
    elseif m.models_module === nothing
      set_string!(buf, inner.x, inner.y + 2, "  ⚠ No models_module provided — pass it to tui()", tstyle(:warning))
    end
  end

  if !isempty(m.insp_error)
    set_string!(buf, inner.x, inner.y + 2, "Error: $(m.insp_error)", tstyle(:error))
  end
end

function _render_insp_result!(m::PormGDashboard, area::Rect, buf)
  inner = render(Block(title="Inspection Result"), area, buf)

  lines = String[]

  if m.insp_result === nothing
    push!(lines, "No query inspected yet.")
    push!(lines, "")
    push!(lines, "Type a model name above and press [Enter].")
    push!(lines, "")
    push!(lines, "Format: ModelName [filter_key=value ...]")
    push!(lines, "")
    push!(lines, "Examples:")
    push!(lines, "  Driver")
    push!(lines, "  Result driverid__forename=Lewis positionorder=1")
    push!(lines, "  Constructor nationality=British")
  else
    r = m.insp_result

    push!(lines, "Model:     $(get(r, :model, "?"))")
    push!(lines, "Operation: $(get(r, :operation, "?"))")
    push!(lines, "Dialect:   $(get(r, :dialect, "?"))")
    push!(lines, "Bucketing: $(get(r, :bucketing, "?"))")
    push!(lines, "Params:    $(get(r, :parameter_count, 0))")

    push!(lines, "")
    push!(lines, "── Parameters ──")
    params = get(r, :parameters, [])
    if isempty(params)
      push!(lines, "  (none)")
    else
      for (i, p) in enumerate(params)
        push!(lines, "  [$i] $(repr(p))")
      end
    end

    # Bucket breakdown (SQLite)
    buckets = get(r, :parameter_buckets, Dict())
    if !isempty(buckets)
      push!(lines, "")
      push!(lines, "── Parameter Buckets ──")
      for (name, vals) in sort(collect(buckets), by=first)
        isempty(vals) && continue
        push!(lines, "  $name: $(repr(vals))")
      end
    end

    push!(lines, "")
    push!(lines, "── Generated SQL ──")
    sql = get(r, :sql_text, "")
    for line in split(sql, "\n")
      push!(lines, "  $line")
    end
  end

  # Append log
  push!(lines, "")
  push!(lines, "── Log ──")
  max_log = max(1, 5)
  log_slice = m.insp_log[max(1, end - max_log + 1):end]
  append!(lines, log_slice)

  render(ScrollPane(lines; following=true), inner, buf)
end

# ==========================================================================
# Public launcher — overrides the PormG.tui() stub
# ==========================================================================

"""
    pormg_tui(db_path::String; fps=30)

Launch the PormG terminal dashboard with Migrations and Query Inspection panes.

# Arguments
- `db_path`: Path to the database environment folder (e.g., "test/integration/db_2")
- `fps`: Target frame rate (default: 30)

# Key Bindings
- `F1` — Switch to Migrations pane
- `F2` — Switch to Inspection pane
- `s`  — (Migrations) Load migration status
- `d`  — (Migrations) Run dry_run
- `i`  — (Migrations) Initialize migrations table
- `m`  — (Migrations) Apply pending migrations (safe only)
- `j/k` — (Migrations) Scroll SQL preview
- `Enter` — (Inspection) Run query inspection
- `Esc` — Quit

# Example
```julia
using PormG, Tachikoma
PormG.tui("test/integration/db_2")
```
"""
function pormg_tui(db_path::String; models_module::Union{Nothing, Module}=nothing, fps::Int=30)
  Sys.iswindows() && error(
    "PormG.tui() is not supported on Windows yet. " *
    "Tachikoma currently depends on Unix-style file descriptor calls such as `dup` inside its app loop. " *
    "Use Linux/macOS/WSL for now, or use the non-TUI migration workflow on Windows."
  )
  model = PormGDashboard(db_path=db_path, models_module=models_module)
  app(model; fps=fps, default_bindings=true)
end

# Override the fallback in PormG
function __init__()
  @eval PormG begin
    """
        tui(db_path::String; models_module=nothing, fps=30)

    Launch the PormG terminal dashboard. Requires Tachikoma.jl.
    Provides interactive Migrations status/dry_run/migrate and Query Inspection panes.

    # Arguments
    - `db_path`: Path to the database environment folder (e.g., "test/integration/db_2")
    - `models_module`: The Julia module containing your PormG model definitions (for query inspection)
    - `fps`: Target frame rate (default: 30)

    # Example
    ```julia
    using PormG, Tachikoma
    PormG.@import_models "db_2/models.jl" models
    import .models as M
    PormG.tui("test/integration/db_2"; models_module=M)
    ```
    """
    function tui(db_path::String; models_module::Union{Nothing, Module}=nothing, fps::Int=30)
      Base.invokelatest($pormg_tui, db_path; models_module=models_module, fps=fps)
    end
  end
end

end # module PormGTachikomaExt
