# ==============================================================================
# UNIT TESTS: a `__` path that ends at a relation, and an unknown name past the first hop (#1134)
#
# A path's last segment must be a column. When it is a relation instead — a reverse accessor, a
# ManyToMany field, or the reverse side of one — PormG used to say "the column X not found" while
# listing X among the reverse accessors (and omitting a ManyToMany field altogether). Every hop now
# refuses it with one message that names the relation and asks for a column after it, still as an
# `UnknownFieldError`. Separately, an unknown name before the last segment, past the first hop, now
# reports through the #446 `_unknown_field` funnel, as it does at the first hop.
#
# The join-cardinality matrix records one cell per shape; this file pins the parts of the message the
# matrix's 120-character cut does not reach — the remedy and its example.
# DB-free: mock connections, statements built through `inspect_query`.
# ==============================================================================

using Test
using PormG
using PormG.QueryBuilder: inspect_query

struct RelTermMockSQLite <: PormG.PormGSQLite end
PormG.backend_sqlite_version(::RelTermMockSQLite) = 3045000

PormG.config["reltermdb"] = PormG.Configuration.Settings(
  connections = RelTermMockSQLite(), change_data = true, db_def_folder = "reltermdb")

# F1-shaped: a race is held at a circuit, a result belongs to a race and a constructor, and a
# constructor has sponsors (a ManyToMany, reversed on `Sponsor` as `constructors`).
module RelTermModels
  import PormG
  import PormG.Models
  Circuit = Models.Model("circuit",
    circuitid = Models.IDField(),
    name = Models.CharField(),
    location = Models.CharField(),
  )
  Race = Models.Model("race",
    raceid = Models.IDField(),
    year = Models.IntegerField(),
    circuitid = Models.ForeignKey(Circuit, on_delete = "CASCADE", related_name = "races"),
  )
  Sponsor = Models.Model("sponsor",
    sponsorid = Models.IDField(),
    name = Models.CharField(),
  )
  Constructor = Models.Model("constructor",
    constructorid = Models.IDField(),
    name = Models.CharField(),
    sponsors = Models.ManyToManyField(Sponsor, related_name = "constructors"),
  )
  Result = Models.Model("result",
    resultid = Models.IDField(),
    points = Models.IntegerField(),
    raceid = Models.ForeignKey(Race, on_delete = "CASCADE", related_name = "results"),
    constructorid = Models.ForeignKey(Constructor, on_delete = "CASCADE", related_name = "results"),
  )
  # A lap time is keyed by (race, lap): two primary-key fields, so there is no one column to suggest.
  Lap_time = Models.Model("lap_time",
    raceref = Models.CharField(primary_key = true, max_length = 10),
    lap = Models.CharField(primary_key = true, max_length = 10),
    milliseconds = Models.IntegerField(),
    circuitid = Models.ForeignKey(Circuit, on_delete = "CASCADE", related_name = "lap_times"),
  )
  PormG.Models.set_models(@__MODULE__, "reltermdb")
end
const RT = RelTermModels

# The exception a query raises when its statement is built, and its message without ANSI codes —
# `_emsg` keeps them under `--color=yes`, so a needle spanning a coloured token would pass only off-TTY.
function _relterm_error(q)
  try
    inspect_query(q)
  catch e
    return e, replace(e.msg, r"\e\[[0-9;]*m" => "")
  end
  error("expected the statement build to raise, and it built")
end

# ─────────────────────────────────────────────────────────────────────────────
# Relation-terminal paths: one refusal at every hop and for every relation kind
# Each path ends at a relation, so it names no column and builds no SQL. The refusal is an
# `UnknownFieldError` that quotes the full path, says what kind of relation the last segment is and
# where it leads, and shows `<path>__<column>` with the target's primary key as the example. Before
# #1134 the message read "the column X not found" — beside a list that contained X — so every
# assertion below would fail against the old text, not just the "not found" one.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a path ending at a relation is refused as a relation, at every hop (#1134)" begin
  # (case, query, path, last segment, kind, from, to, example column)
  cases = (
    ("reverse accessor, no hop",
     RT.Race.objects.values("raceid", "results"),
     "results", "results", "reverse relation", "race", "result", "resultid"),
    ("reverse accessor, first hop",
     RT.Circuit.objects.values("circuitid", "races__results"),
     "races__results", "results", "reverse relation", "race", "result", "resultid"),
    ("reverse accessor after forward hops (the loop)",
     RT.Result.objects.values("resultid", "raceid__circuitid__races"),
     "raceid__circuitid__races", "races", "reverse relation", "circuit", "race", "raceid"),
    ("reverse accessor in a filter key",
     RT.Race.objects.filter("circuitid__races" => 1).values("raceid"),
     "circuitid__races", "races", "reverse relation", "circuit", "race", "raceid"),
    # A plain filter key is resolved by the projection-alias branch (`build_filter.jl`), not the join
    # builder — the review of #1134 found it still giving the old message.
    ("reverse accessor as a plain filter key",
     RT.Race.objects.filter("results" => 1).values("raceid"),
     "results", "results", "reverse relation", "race", "result", "resultid"),
    ("ManyToMany field as a plain filter key, with a lookup",
     RT.Constructor.objects.filter("sponsors__@isnull" => true).values("constructorid"),
     "sponsors", "sponsors", "ManyToMany field", "constructor", "sponsor", "sponsorid"),
    ("ManyToMany field, no hop",
     RT.Constructor.objects.values("constructorid", "sponsors"),
     "sponsors", "sponsors", "ManyToMany field", "constructor", "sponsor", "sponsorid"),
    ("ManyToMany field after a hop",
     RT.Result.objects.values("resultid", "constructorid__sponsors"),
     "constructorid__sponsors", "sponsors", "ManyToMany field", "constructor", "sponsor", "sponsorid"),
    ("reverse ManyToMany accessor after a ManyToMany hop",
     RT.Result.objects.values("resultid", "constructorid__sponsors__constructors"),
     "constructorid__sponsors__constructors", "constructors", "reverse ManyToMany accessor", "sponsor",
     "constructor", "constructorid"),
  )
  for (case, q, path, last, kind, from, to, pk) in cases
    @testset "$(case)" begin
      e, msg = _relterm_error(q)
      @test e isa PormG.UnknownFieldError
      # Names the path and the relation it ends at, and what that relation is.
      @test startswith(msg, "the path $(path) ends at $(last), a $(kind) from $(from) to $(to), not a column.")
      # The remedy: a column after the relation, with a real one as the example.
      @test occursin("$(path)__<column>", msg)
      @test occursin("(e.g. $(path)__$(pk))", msg)
      # The contradiction the issue reported is gone.
      @test !occursin("not found", msg)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Relation-terminal: a target with no single-column key
# The example column is the target's primary key, so a target keyed by two fields has none to give.
# The refusal must still be the same `UnknownFieldError`, just without the example — a lookup that
# throws on a composite key (`Models.get_model_pk_field`) would turn it into a `ModelDefinitionError`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a relation to a two-field-key model is refused without an example (#1134)" begin
  e, msg = _relterm_error(RT.Circuit.objects.values("circuitid", "lap_times"))
  @test e isa PormG.UnknownFieldError
  @test startswith(msg, "the path lap_times ends at lap_times, a reverse relation from circuit to lap_time, not a column.")
  @test occursin("lap_times__<column>", msg)
  @test !occursin("(e.g.", msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# Relation-terminal: the corrected path builds
# The remedy the message gives is real: the same path with the suggested column after the relation
# renders a statement projecting it. Guards against a check that refuses a relation in a NON-terminal
# position too — so, unlike the testsets above, this one passes on the unpatched code as well.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the path the message suggests builds (#1134)" begin
  for path in ("raceid__circuitid__races__raceid",
               "constructorid__sponsors__sponsorid",
               "constructorid__sponsors__constructors__constructorid")
    sql = inspect_query(RT.Result.objects.values("resultid", path))[:sql_text]
    @test occursin("as \"$(path)\"", sql)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Unknown names: the funnel's message at every hop
# An unknown name before the last segment, past the first hop, reached the join loop's own `else`,
# which said "Invalid field path: the column nope not found in circuit" without the names that ARE
# available. It now goes through `_unknown_field`, like the first hop: the fields sorted, and the
# reverse accessors listed. An unknown LAST segment is not a relation, so it keeps the "not found" text.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an unknown name past the first hop reports through the #446 funnel (#1134)" begin
  e, msg = _relterm_error(RT.Result.objects.values("resultid", "raceid__circuitid__nope__name"))
  @test e isa PormG.UnknownFieldError
  @test startswith(msg, "the column nope not found in circuit, that contains the fields: circuitid, location, name; " *
                        "and the reverse accessors: lap_times, races")
  @test !occursin("Invalid field path", msg)

  # The terminal twin: still "not found", and not mistaken for a relation.
  e, msg = _relterm_error(RT.Result.objects.values("resultid", "raceid__circuitid__nope"))
  @test e isa PormG.UnknownFieldError
  @test startswith(msg, "the column nope not found in circuit, that contains the fields: circuitid, location, name")
end
