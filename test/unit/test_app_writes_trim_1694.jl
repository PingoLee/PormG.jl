# ============================================================
# test/unit/test_app_writes_trim_1694.jl
#
# CONTRACT being tested (#1694, the two error-type changes of the round; upgrading/2026-11-23-1694-*.md):
#   - an `INSERT … RETURNING` that returns no row (a trigger or rule skipped it) raises `StatementError` from `create`
#     and `update_or_create` on PostgreSQL, naming the operation and the model, where it raised a raw `BoundsError`;
#   - a `columns=` name the model has no field for raises `UnknownFieldError` from `bulk_insert` and `bulk_copy`, the
#     text `bulk_update` already gives, where it raised a raw `KeyError`.
#   Each old trigger is exercised: the empty rows the old read indexed, and the unknown name the old lookup missed.
#   And the `filters=` normalization retyped so a trimmed binary runs two pairs of different value types
#   (`_norm_bulk_filter`, #1599 layer 7) gives what the closure it replaced gave, for every entry it admits.
#
# Hermetic: a stand-in PostgreSQL pool whose `fetch` returns no row, and an in-memory SQLite database.
#
# Run: julia --project=test/integration test/unit/test_app_writes_trim_1694.jl
# ============================================================

using Test
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using PormG
using Dates
const Tables = PormG.QueryBuilder.Tables   # not a dependency of the test environments

const _AW_QB = PormG.QueryBuilder

# A PostgreSQL whose every statement returns no row: an `INSERT … RETURNING` that a trigger skipped.
struct AwNoRowPg <: PormG.PormGPostgres end
PormG.config["aw_norow"] = PormG.Configuration.Settings(connections = AwNoRowPg(), change_data = true,
                                                         db_def_folder = "aw_norow")
PormG.ConnectionPool.fetch(::AwNoRowPg, sql::String; kwargs...) = NamedTuple[]
module AwPgModels
import PormG, PormG.Models
Aw_race::PormG.Models.ModelType = Models.Model("aw_race",
  raceid = Models.IDField(),
  year   = Models.IntegerField(),
  round  = Models.IntegerField(),
  name   = Models.CharField(max_length = 80),
)
Models.@models Aw_race
PormG.Models.set_models(@__MODULE__, "aw_norow")
end

module AwSlModels
import PormG, PormG.Models
Aw_race::PormG.Models.ModelType = Models.Model("aw_race",
  raceid = Models.IDField(),
  year   = Models.IntegerField(),
  round  = Models.IntegerField(),
  name   = Models.CharField(max_length = 80),
)
Models.@models Aw_race
end

# The message without ANSI: `_emsg` keeps the colour codes when the session has colour (CI's `--color=yes`).
_aw_outcome(f) = try
  (:value, f())
catch e
  (:raised, typeof(e), replace(sprint(showerror, e), r"\e\[[0-9;]*m" => ""))
end

@testset "the round's write changes: two typed errors and the filters= walk (#1694)" begin

  # What: `create` and `update_or_create` on PostgreSQL when the `INSERT … RETURNING` returns no row.
  # Expected: `StatementError` naming the operation and the model; the old read of those rows raised `BoundsError`.
  # Why: a trigger or rule that skips the insert is a refused statement, not an indexing bug in the caller's code; the
  #   typed error is what `catch DatabaseError` handles, as `update_or_create` on MySQL already raises.
  @testset "an empty RETURNING is a StatementError, not a BoundsError" begin
    # The old trigger: the old read indexed the empty rows.
    @test _aw_outcome(() -> Tables.rowtable(NamedTuple[]) |> Base.first)[2] === BoundsError
    R = AwPgModels.Aw_race
    for (op, f) in (("create", () -> R.objects.create("year" => 2009, "round" => 6, "name" => "Monaco Grand Prix")),
                    ("update_or_create", () -> R.objects.update_or_create("raceid" => 40;
                                                                         defaults = Dict("year" => 2009, "round" => 6,
                                                                                         "name" => "Monaco Grand Prix"))))
      r = _aw_outcome(f)
      @test (op, r[1], r[2]) == (op, :raised, PormG.StatementError)
      @test occursin("$(op): the statement returned no aw_race row: a trigger or rule may have skipped it.", r[3])
    end
  end

  # What: `bulk_insert` (and `bulk_copy`'s shared preparation) with a `columns=` name the model has no field for, bare and
  #   as a pair's target, from rows and from a column table.
  # Expected: `UnknownFieldError` with the text `bulk_update` gives; nothing written.
  # Why: a column list built from a table's names (`names(df)`) with an extra column raised a raw `KeyError`, which no
  #   `catch UsageError` handles.
  @testset "an unknown columns= field is an UnknownFieldError, not a KeyError" begin
    dir = mktempdir()
    PormG.Configuration.register_connection("aw_sqlite", joinpath(dir, "f1.sqlite"); adapter = "SQLite", env = "prod",
                                            pool_size = 1, change_db = true, change_data = true)
    PormG.Models.set_models(AwSlModels; key = "aw_sqlite")
    R = AwSlModels.Aw_race
    PormG.Migrations.ensure_table!(R, "aw_sqlite")
    row = (year = 2030, round = 1, name = "X", nosuch = 5)
    for (label, f, text) in (
        ("bare", () -> PormG.bulk_insert(R.objects, [row]; columns = ["year", "round", "name", "nosuch"]),
         "Error in bulk_insert, the field nosuch not found in aw_race"),
        ("pair target", () -> PormG.bulk_insert(R.objects, [row]; columns = ["year", "round", "name", "nosuch" => "nofield"]),
         "Error in bulk_insert, the field nofield not found in aw_race"),
        ("column table", () -> PormG.bulk_insert(R.objects, (year = [2030], round = [1], name = ["X"], nosuch = [5]);
                                                 columns = ["year", "round", "name", "nosuch"]),
         "Error in bulk_insert, the field nosuch not found in aw_race"))
      r = _aw_outcome(f)
      @test (label, r[1], r[2]) == (label, :raised, PormG.UnknownFieldError)
      @test (label, occursin(text, r[3])) == (label, true)
    end
    @test R.objects.count() == 0
    # `bulk_update` already raised this text; unchanged.
    r = _aw_outcome(() -> PormG.bulk_update(R.objects, [(raceid = 1, nosuch = 5)]; columns = ["nosuch"], match_on = ["raceid"]))
    @test r[2] === PormG.UnknownFieldError && occursin("Error in bulk_update, the field nosuch not found in aw_race", r[3])
    # `bulk_copy` shares the preparation (`_prepare_bulk_df!` with `:copy`): the same refusal, named for it. Called directly
    # here, since `bulk_copy` itself is PostgreSQL's.
    settings = PormG.Configuration.get_settings("aw_sqlite")
    frame = _AW_QB._bulk_frame([row], "bulk_copy")
    cols = _AW_QB._normalize_bulk_columns(["year", "round", "name", "nosuch"])
    r = _aw_outcome(() -> _AW_QB._prepare_bulk_df!(frame, R, cols, :copy, settings))
    @test r[2] === PormG.UnknownFieldError && occursin("Error in bulk_copy, the field nosuch not found in aw_race", r[3])
    PormG.Configuration.close_pool!("aw_sqlite")
  end

  # What: `_norm_bulk_filter` against the closure `_normalize_bulk_filters` used (`String(f.first) => f.second`), for each
  #   value type and key type a `filters=` entry can hold, and the whole normalization for a list of mixed value types.
  # Expected: the same entries, with the same types, in the same order; the same refusal for an invalid entry.
  # Why: the walk rebuilds each pair at its value's type; a different pair type would bind the filter differently.
  @testset "filters= entries normalize as the closure did" begin
    old_norm(f) = f isa AbstractString ? String(f) : String(f.first) => f.second
    entries = Any["year", SubString("round", 1, 5), "year" => 2008, "name" => "Monaco Grand Prix", "flag" => true,
                  "points" => 2.5, "date" => Date(2008, 5, 25), "ts" => DateTime(2008, 5, 25, 14), "ids" => [1, 2],
                  "names" => ["a", "b"], "round" => Int32(6), SubString("year", 1, 4) => 2008, "x" => nothing,
                  "y" => missing, "z" => Dates.Hour(2)]
    for f in entries
      new = _AW_QB._norm_bulk_filter(f)
      old = old_norm(f)
      @test isequal((typeof(new), new), (typeof(old), old))
    end
    mixed = ["circuitid" => 1, "name" => "Monaco Grand Prix"]
    @test isequal(map(typeof, _AW_QB._normalize_bulk_filters(mixed)), [Pair{String, Int64}, Pair{String, String}])
    # An invalid entry is refused by the vector loop's guard before any entry is normalized, as before: the old
    # normalization is the same loop over the old closure.
    function old_normalize(filters::Vector)
      out = Union{String, Pair{String, <:Any}}[]
      for f in filters
        f isa Union{AbstractString, Pair{<:AbstractString, <:Any}} || throw(PormG.QueryBuildError("Invalid filter specification: $f"))
        push!(out, old_norm(f))
      end
      out
    end
    for bad in (Any["year" => 2008, 5], Any[5], Any["year", :x => 1])
      @test _aw_outcome(() -> _AW_QB._normalize_bulk_filters(bad)) == _aw_outcome(() -> old_normalize(bad))
    end
    @test _aw_outcome(() -> _AW_QB._normalize_bulk_filters(Any["year" => 2008, 5]))[2] === PormG.QueryBuildError
  end
end
