using Test
using PormG
using PormG.Models: Model, IDField, IntegerField
using PormG.QueryBuilder: bulk_update
import DataFrames

# Helpers under test live in the package namespace / QueryBuilder submodule.
const _emsg = PormG._emsg
const _argerr = PormG.QueryBuilder._argerr

# A representative message carrying the same ANSI vocabulary the real call sites
# use: underline + foreground color around the offending token, reset at the end.
const SAMPLE = "the field \e[4m\e[31mpoints\e[0m is not allowed"

# ─────────────────────────────────────────────────────────────────────────────
# Error colorization: _emsg strips ANSI off-TTY, keeps it on-TTY
# The shared `_emsg` helper must drop every `\e[..m` SGR sequence when color is
# disabled (CI logs, file sinks, captured `showerror` strings) and leave the
# message untouched when color is enabled (interactive REPL). The `color` keyword
# pins both branches so the assertion does not depend on how Julia was launched.
# ─────────────────────────────────────────────────────────────────────────────
@testset "_emsg color branches" begin
    # Off-TTY: not a single escape byte may survive.
    stripped = _emsg(SAMPLE; color=false)
    @test !occursin("\e[", stripped)
    @test stripped == "the field points is not allowed"   # text is otherwise intact

    # On-TTY: the codes are preserved verbatim for the REPL.
    colored = _emsg(SAMPLE; color=true)
    @test colored == SAMPLE
    @test occursin("\e[", colored)

    # Plain messages (no ANSI) are returned unchanged in both modes.
    @test _emsg("plain message"; color=false) == "plain message"
    @test _emsg("plain message"; color=true) == "plain message"
end

# ─────────────────────────────────────────────────────────────────────────────
# Error colorization: _argerr routes messages through _emsg
# `_argerr` is the long-tail funnel; #231 makes it return `QueryBuildError` (a `PormGError`)
# instead of `ArgumentError`, still routing the message through `_emsg`. This proves the wiring
# (so a regression that bypasses `_emsg` is caught) without depending on the ambient color mode.
# ─────────────────────────────────────────────────────────────────────────────
@testset "_argerr wiring" begin
    err = _argerr(SAMPLE)
    @test err isa PormG.QueryBuildError     # #231: the funnel now returns QueryBuildError
    # _argerr must produce exactly what _emsg produces under the same color mode.
    @test err.msg == _emsg(SAMPLE)
end

# Run `f()` with `Base.have_color` pinned to `flag`, restoring the prior value
# afterwards. `_emsg`'s default color decision reads `Base.have_color`, so this
# lets the end-to-end assertions below exercise both the strip and keep paths
# deterministically regardless of how the test process was launched (in scripts
# `Base.have_color` is often `nothing`, not a Bool).
function _with_have_color(f, flag::Bool)
    old = Base.have_color
    try
        Base.eval(Base, :(have_color = $flag))
        f()
    finally
        Base.eval(Base, :(have_color = $old))
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Error colorization: real thrown messages honor the color mode end-to-end
# Guard against the exception sites that previously embedded raw escape codes
# (here: Models.Model with no fields, which builds its message via `_emsg`). With
# color forced off the rendered `showerror` text must be free of `\e[` noise; with
# color forced on the codes must survive — proving the message is genuinely routed
# through the TTY-aware helper rather than being plain text either way.
# ─────────────────────────────────────────────────────────────────────────────
@testset "no ANSI leak in real thrown messages" begin
    raise_model = () -> try
        PormG.Models.Model("drivers")   # no fields → example-usage ModelDefinitionError
        nothing
    catch e
        e
    end

    # Color OFF: thrown message and its showerror rendering are ANSI-free.
    _with_have_color(false) do
        err = raise_model()
        @test err isa PormG.ModelDefinitionError
        @test !occursin("\e[", err.msg)
        @test !occursin("\e[", sprint(showerror, err))
    end

    # Color ON: the same site keeps its escape codes for the REPL.
    _with_have_color(true) do
        err = raise_model()
        @test err isa PormG.ModelDefinitionError
        @test occursin("\e[", err.msg)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Error colorization: _emsg(io, msg) keys off the destination stream's color
# The IO-aware overload used inside `show` / `print(io, …)` methods must decide on
# the stream's `:color` IOContext property, NOT the global `Base.have_color`. This
# is the bug class where a plain `IOBuffer` (from `sprint`/`repr`) must stay clean
# even when the process is attached to a color terminal.
# ─────────────────────────────────────────────────────────────────────────────
@testset "_emsg(io, msg) color context" begin
    # A bare IOBuffer advertises no color → strip, regardless of Base.have_color.
    _with_have_color(true) do
        @test !occursin("\e[", _emsg(IOBuffer(), SAMPLE))
    end
    # An IOContext that opts into color → keep.
    @test occursin("\e[", _emsg(IOContext(IOBuffer(), :color => true), SAMPLE))
    # An IOContext that opts out → strip, even on a color terminal.
    _with_have_color(true) do
        @test !occursin("\e[", _emsg(IOContext(IOBuffer(), :color => false), SAMPLE))
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Error colorization: show methods do not leak ANSI into non-color buffers
# End-to-end guard for the migration `Base.show` sites (MigrationStatus) that emit
# colored summary lines. `sprint`/`repr` build a non-color buffer, so the captured
# string must be ANSI-free even when color is on; an explicit color IOContext must
# preserve the codes for the REPL.
# ─────────────────────────────────────────────────────────────────────────────
@testset "no ANSI leak in show methods" begin
    # A status with a failed migration, a pending file, and a drift signal — this
    # exercises all three colored branches of `Base.show(::MigrationStatus)`.
    status = PormG.Migrations.MigrationStatus(
        NamedTuple[],                          # applied
        [(version = "0001", name = "init")],   # failed   → red line
        true,                                  # pending  → yellow line
        true,                                  # has_history_table
        ["schema drift detected"],             # drift_signals → yellow line
    )

    _with_have_color(true) do
        # Captured via sprint (non-color buffer): must be clean despite color on.
        @test !occursin("\e[", sprint(show, status))
        # Explicit color context: codes are preserved.
        @test occursin("\e[", sprint(io -> show(IOContext(io, :color => true), status)))
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Error colorization: real bulk error paths route through _argerr end-to-end
# The bulk validation sites in `execution_bulk.jl` build ANSI-highlighted messages
# and were converted from raw `throw`/`throw(_emsg(...))` to `_argerr`. This drives
# a genuine `bulk_update` failure (unknown `match_on` field) and asserts both the
# behavior — an `ArgumentError`, never a bare `String` — and the off-TTY contract:
# no `\e[` when color is off, codes preserved when on. No live DB is needed; a mock
# Postgres scope plus `show_query=:dict` returns before any network call.
# ─────────────────────────────────────────────────────────────────────────────
struct _AnsiBulkMockPg <: PormG.PormGPostgres end
PormG.config["ansi_bulk_default"] = PormG.Configuration.Settings(
    connections = _AnsiBulkMockPg(),
    change_data = true,
)

@testset "no ANSI leak in bulk error messages" begin
    model = Model("ansi_bulk_metrics", id = IDField(), weight = IntegerField(null = true))
    model.connect_key = "ansi_bulk_default"
    df = DataFrames.DataFrame(id = [1], weight = [5])

    # `match_on = ["not_a_field"]` fails the model-field check in execution_bulk.jl
    # (`bulk_update: match_on field … is not a field of model`) → UnknownFieldError (#231).
    raise_bulk = () -> try
        bulk_update(model.objects, df;
            columns = ["weight"], match_on = ["not_a_field"], show_query = :dict)
        nothing
    catch e
        e
    end

    _with_have_color(false) do
        err = raise_bulk()
        @test err isa PormG.UnknownFieldError             # #231: field-not-found, not a raw String
        @test !occursin("\e[", err.msg)
        @test !occursin("\e[", sprint(showerror, err))
    end

    _with_have_color(true) do
        err = raise_bulk()
        @test err isa PormG.UnknownFieldError
        @test occursin("\e[", err.msg)                    # highlighting kept on-TTY
    end
end
