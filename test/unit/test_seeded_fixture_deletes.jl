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
# A `delete(…)` call and its receiver, matched over the whole file so a call split across lines is seen.
const _SFD_CALL = r"([\w.]+)\s*\.\s*delete\s*\(([^()]*)\)"s
const _SFD_LITERAL = r"^M\.(\w+)\.objects$"

# Every delete-all of a seeded model in `text`, as `(line, model)`. The receiver is written at the call
# (`M.Status.objects.delete(…)`) or is a variable bound earlier in the file (`query = M.Status.objects`, or
# a filtered `M.Status.objects.filter(…)`, which errs towards a hit), resolved to its nearest preceding
# binding. A receiver the scan cannot resolve (a function's return, a loop variable) is not reported.
function _sfd_hits(text::AbstractString)::Vector{Tuple{Int,String}}
  hits = Tuple{Int,String}[]
  for m in eachmatch(_SFD_CALL, text)
    args = m.captures[2]
    occursin(_SFD_DELETE_ALL, args) || continue
    occursin(_SFD_INSPECT_ONLY, args) && continue
    line = count(==('\n'), SubString(text, 1, m.offset)) + 1
    linestart = something(findprev(==('\n'), text, m.offset), 0) + 1
    startswith(lstrip(SubString(text, linestart, m.offset)), "#") && continue   # a comment
    recv = m.captures[1]
    lit = match(_SFD_LITERAL, recv)
    model = lit === nothing ? nothing : String(lit.captures[1])
    if model === nothing && occursin(r"^\w+$", recv)
      bind = Regex("\\b" * recv * raw"\s*=\s*M\.(\w+)\.objects\b")
      before = SubString(text, 1, m.offset - 1)
      found = collect(eachmatch(bind, before))
      isempty(found) || (model = String(last(found).captures[1]))
    end
    model !== nothing && model in _SFD_SEEDED && push!(hits, (line, model))
  end
  return hits
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
    for (line, model) in _sfd_hits(read(joinpath(dir, f), String))
      push!(hits, "test/integration/$(f):$(line) deletes every $(model) row")
    end
  end
  @test hits == String[]

  # The seeder still writes each model the scan protects, so the list cannot drift from it silently.
  # `\b…\.objects`, so `M.Driver` is not satisfied by `M.Driver_standings`.
  seeder = read(joinpath(dir, _SFD_SEEDER), String)
  for model in _SFD_SEEDED
    @test occursin(Regex("\\bM\\.$(model)\\.objects\\b"), seeder)
  end

  # The scan sees each spelling it is for, and lets the safe ones through.
  sample = """
    query = M.Status.objects
    query.delete(allow_delete_all=true)
    M.Result.objects.delete(allow_delete_all = true)
    M.Lap_times.objects.delete(allow_delete_all = true, show_query = :dict)
    M.Just_a_test_deletion.objects.delete(allow_delete_all=true)
    scratch().delete(allow_delete_all = true)
    q = M.Status.objects; q.filter("statusid__@in" => ids); q.delete()
    # M.Driver.objects.delete(allow_delete_all = true)
    M.Circuit.objects.delete(
        allow_delete_all = true)
    """
  @test _sfd_hits(sample) == [(2, "Status"), (3, "Result"), (9, "Circuit")]
end
