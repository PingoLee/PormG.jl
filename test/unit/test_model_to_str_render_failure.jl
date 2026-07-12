# ============================================================
# test/unit/test_model_to_str_render_failure.jl
#
# Model_to_str render-failure surfacing (#70).
#
# CONTRACT being tested:
#   A field whose string rendering throws must NEVER be silently dropped from the generated
#   model string. Following the inspectdb/schema-dump convention, Model_to_str emits a
#   structured @warn AND a visible `# PormG: field '<name>' (<Type>) could not be rendered: …`
#   marker comment directly above the model definition, then keeps rendering the remaining
#   fields — one bad column must not abort a multi-table import. Healthy fields render with
#   no marker and no warning.
#
# Deterministic, DB-free. Mutation gate: reverting the fix (restoring the empty `catch e` in
# Models.jl Model_to_str) drops the throwing field silently — the marker assertion and the
# @test_logs (:warn,) assertion below both fail.
# ============================================================

using Test
using Logging
using PormG
using PormG.Models: CharField

# A field type whose RENDERING throws. Model_to_str derives the emitted constructor name by
# stripping the struct name's first character (sCharField → CharField), so this type resolves
# to `ThrowingRenderField` — which has no binding inside the Models module. The render helper
# `_model_to_str_general` then raises UndefVarError at `getfield(@__MODULE__, struct_name)()`,
# with no monkey-patching needed.
struct _ThrowingRenderField <: PormG.PormGField
  payload::Any
end

# Bare Model_Type around a fields dict — bypasses the Model() constructor (and any config/FK
# resolution) so the test isolates the rendering loop only, mirroring test_migration_diff_failsafe.jl.
_mk_render_model(fields::Dict{String, PormG.PormGField}) =
  PormG.Models.Model_Type(name = "drivers_render_scratch", fields = fields)

# Model_to_str only reads settings.django_prefix (nothing by default) — an all-default
# Settings is a sufficient stand-in for a real connection config here.
const RENDER_SETTINGS = PormG.Configuration.Settings()

# ─────────────────────────────────────────────────────────────────────────────
# Model_to_str: render-failure surfacing (#70)
# A field whose rendering throws must produce a structured @warn plus a visible marker
# comment in the generated model string (inspectdb convention) — never a silent drop —
# while healthy fields keep rendering and healthy models stay marker- and warning-free.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Model_to_str render failure surfaced (#70)" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # Criterion (issue #70): a field that raises in _model_to_str_general is surfaced —
  # structured warn + marker comment in the artifact — and the healthy field still renders.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "throwing field → warn + marker comment, healthy field kept" begin
    m = _mk_render_model(Dict{String, PormG.PormGField}(
      "surname" => CharField(),                       # healthy control field
      "validade" => _ThrowingRenderField(nothing),    # rendering raises UndefVarError
    ))

    # The warn must fire with the render-failure message — pinning the message ensures a
    # degraded contentless @warn can't satisfy the test (match_mode=:any tolerates the @info
    # that prints the final string). @test_logs returns the expression value.
    s = @test_logs (:warn, r"field render failed") match_mode=:any PormG.Models.Model_to_str(m, RENDER_SETTINGS)

    # The gap is visible in the artifact itself: marker names the field and its type.
    @test occursin("# PormG: field 'validade' (ThrowingRenderField) could not be rendered", s)
    # The marker sits ABOVE the model definition (start of the string), keeping the code valid.
    @test startswith(s, "# PormG:")
    # The throwing field is omitted from the constructor call — never half-rendered.
    @test !occursin("validade = Models.", s)
    # The healthy field still renders normally: one bad field must not poison its neighbors.
    @test occursin("surname = Models.CharField", s)
    @test occursin("""Models.Model("drivers_render_scratch\"""", s)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Negative case: an all-healthy model renders with NO marker and NO warning — the guard
  # fires only when rendering actually fails.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "healthy model → no marker, no warn" begin
    m_ok = _mk_render_model(Dict{String, PormG.PormGField}(
      "surname" => CharField(),
    ))

    # min_level=Warn asserts NOTHING at warn-or-above is logged (the @info passes underneath).
    s_ok = @test_logs min_level=Logging.Warn PormG.Models.Model_to_str(m_ok, RENDER_SETTINGS)

    @test !occursin("# PormG:", s_ok)
    @test occursin("surname = Models.CharField", s_ok)
    @test startswith(s_ok, "Drivers_render_scratch = Models.Model(")
  end

end
