# ==============================================================================
# No integration file empties a seeded F1 table but the seeder (#1764)
#
# The F1 fixture tables are seeded by `test/integration/test_database_setup.jl`, and db_2 is one
# database shared by every checkout. An integration file is a valid target on its own (CONTRIBUTING.md
# → Verification), and then nothing reseeds after it. `test_inserts.jl` emptied `status` with
# `delete(allow_delete_all = true)`: the delete cascaded into `result`, and every other session's read
# of either table failed until a full `runtests.jl` ran again. This scan fails when an integration file
# other than the seeder deletes every row of a seeded model. A file that writes a seeded table removes
# only the rows it wrote, by id.
#
# Run: julia --project=test/integration test/unit/test_seeded_fixture_deletes.jl
# ==============================================================================

using Test
using PormG
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))

# The models `test_database_setup.jl` seeds (its delete-and-reload list, plus `Race`).
const _SFD_SEEDED = ("Status", "Circuit", "Race", "Driver", "Constructor", "Result", "Driver_standings",
                     "Lap_times", "Pit_stops", "Qualifying", "Sprint_results", "Constructor_results",
                     "Constructor_standings")
const _SFD_SEEDER = "test_database_setup.jl"

const _SFD_DELETE_ALL = r"allow_delete_all\s*=\s*true"
# A query that is only rendered, never executed, deletes nothing.
const _SFD_INSPECT_ONLY = r"show_query\s*=\s*:(sql|dict)\b"
const _SFD_LITERAL = r"\bM\.(\w+)\.objects\b"
const _SFD_RECEIVER = r"\b(\w+)\s*\.\s*delete\s*\("

# The seeded model a delete-all line in `lines[i]` targets, or `nothing`. The receiver is either written on
# the line (`M.Status.objects.delete(…)`) or a variable bound earlier in the file (`query = M.Status.objects`),
# which is resolved to its nearest preceding assignment.
function _sfd_target(lines::Vector{String}, i::Int)::Union{Nothing,String}
  l = lines[i]
  occursin(_SFD_DELETE_ALL, l) || return nothing
  occursin(_SFD_INSPECT_ONLY, l) && return nothing
  m = match(_SFD_LITERAL, l)
  model = m === nothing ? nothing : String(m.captures[1])
  if model === nothing
    r = match(_SFD_RECEIVER, l)
    r === nothing && return nothing
    bind = Regex("\\b" * r.captures[1] * raw"\s*=\s*M\.(\w+)\.objects\b")
    for j in i-1:-1:1
      b = match(bind, lines[j])
      b === nothing && continue
      model = String(b.captures[1])
      break
    end
  end
  return model !== nothing && model in _SFD_SEEDED ? model : nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# Integration fixtures: only the seeder deletes every row of a seeded F1 model (#1764)
# Scans test/integration/*.jl for `allow_delete_all = true` on a seeded model, resolving a receiver held
# in a variable. Expected: no hit outside test_database_setup.jl. Why: db_2 is shared, so one file run on
# its own that empties `status` breaks every other session's reads of `status` and `result`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1764: only the seeder deletes every row of a seeded F1 table" begin
  dir = joinpath(pkgdir(PormG), "test", "integration")
  files = filter(f -> endswith(f, ".jl"), readdir(dir))
  @test length(files) > 50          # the directory was read, so an empty result means something
  hits = String[]
  for f in files
    f == _SFD_SEEDER && continue
    lines = readlines(joinpath(dir, f))
    for i in eachindex(lines)
      startswith(lstrip(lines[i]), "#") && continue
      model = _sfd_target(lines, i)
      model === nothing || push!(hits, "test/integration/$(f):$(i) deletes every $(model) row")
    end
  end
  @test hits == String[]

  # The seeder still seeds each model the scan protects, so the list cannot drift from it silently.
  seeder = read(joinpath(dir, _SFD_SEEDER), String)
  for model in _SFD_SEEDED
    @test occursin("M.$(model)", seeder)
  end

  # The scan sees each spelling it is for, and lets the safe ones through.
  sample = ["query = M.Status.objects",
            "query.delete(allow_delete_all=true)",
            "M.Result.objects.delete(allow_delete_all = true)",
            "M.Lap_times.objects.delete(allow_delete_all = true, show_query = :dict)",
            "M.Just_a_test_deletion.objects.delete(allow_delete_all=true)",
            "scratch().delete(allow_delete_all = true)",
            "q = M.Status.objects; q.filter(\"statusid__@in\" => ids); q.delete()"]
  @test _sfd_target(sample, 2) == "Status"
  @test _sfd_target(sample, 3) == "Result"
  @test _sfd_target(sample, 4) === nothing
  @test _sfd_target(sample, 5) === nothing
  @test _sfd_target(sample, 6) === nothing
  @test _sfd_target(sample, 7) === nothing
end
