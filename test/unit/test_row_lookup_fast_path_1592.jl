"""
A row read looks the stored key up first, and normalizes only on a miss (#1592).

Every `row.field`, `row[:field]`, `row["field"]`, `haskey(row, …)`, `get(row, …, default)` and
`Tables.getcolumn(row, …)` went through `_normalize_row_symbol`, which since #317 returns the Symbol it
was handed, after building a `String`, a `split` vector, a `String` per part, a `join` and a new
intern to get there. A handler reading five fields of twenty rows paid that a hundred times per
request, after the query had finished (#41). Now a stored key is answered by one `Dict` lookup and
allocates nothing.

What this file pins is the MISS path, which must answer exactly as before the fast path existed:
the empty-segment refusal (`row.a__`), the `.pk` alias, the many-to-many accessor, the lazy
foreign-key refusal (`LazyTraversalError`) and the unknown-name refusal, plus `haskey`/`get` on a
key the row does not hold. No SQL is rendered or executed anywhere in this file: the rows are
built from a `Dict` and a model, which is all a row read touches.

DB-free: the models below have a mock backend that answers nothing, and nothing here reaches it.
"""

using Test
using DataFrames
using PormG
import PormG.ConnectionPool: fetch
import PormG.QueryBuilder: PormGRow
import PormG: UnknownFieldError, LazyTraversalError
const Tables = PormG.QueryBuilder.Tables   # no new test dependency

struct MockRowLookup1592 <: PormG.PormGPostgres end
fetch(::MockRowLookup1592, sql::String; conn = nothing, params = nothing, ignore_tx::Bool = false) =
  DataFrame()
PormG.config["row_lookup_1592"] = PormG.Configuration.Settings(
  connections = MockRowLookup1592(), change_data = true, db_def_folder = "row_lookup_1592")

# Registered with `set_models`, which the many-to-many accessor resolves its through model from.
module RowLookup1592Models
import PormG
import PormG.Models
Constructor = Models.Model("rl1592_constructor", constructorid = Models.IDField(), name = Models.CharField())
Driver = Models.Model("rl1592_driver",
  driverid      = Models.IDField(),
  surname       = Models.CharField(),
  points        = Models.IntegerField(),
  constructorid = Models.ForeignKey(Constructor, pk_field = "constructorid", related_name = "drivers_fk"),
  teams         = Models.ManyToManyField(Constructor, related_name = "drivers"))
PormG.Models.set_models(@__MODULE__, "row_lookup_1592")
end
const RL = RowLookup1592Models

_senna() = PormGRow(Dict{Symbol,Any}(:driverid => 1, :surname => "Senna", :points => 10,
                                      :constructorid__name => "McLaren"), RL.Driver)

# Behind a function barrier, so `@allocated` measures the read and not the call into a closure.
_alloc_getproperty(row) = @allocated row.surname
_alloc_getindex(row) = @allocated row[:surname]
_alloc_haskey(row) = @allocated haskey(row, :surname)
_alloc_get(row) = @allocated get(row, :surname, nothing)
_alloc_getcolumn(row) = @allocated Tables.getcolumn(row, :surname)
_alloc_path(row) = @allocated row.constructorid__name

# ─────────────────────────────────────────────────────────────────────────────
# A stored key is read without allocating (#1592)
# The fix's own claim, measured: a hit returns the stored value through one `Dict` lookup. Before
# the fix each of these allocated a `String`, a `split` vector, a `String` per segment and a
# `join` (464 bytes for `row.surname`). The values are asserted too, so a fast path that returned
# the wrong slot would fail here rather than merely allocate less.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a stored key is read without allocating (#1592)" begin
  row = _senna()
  @test row.surname == "Senna"
  @test row[:surname] == "Senna"
  @test row["surname"] == "Senna"
  @test row[SubString("surname,points", 1, 7)] == "Senna"   # #612's SubString read
  @test haskey(row, :surname) && haskey(row, "surname")
  @test get(row, :surname, nothing) == "Senna"
  @test get(row, "surname", nothing) == "Senna"
  @test Tables.getcolumn(row, :surname) == "Senna"
  @test row.constructorid__name == "McLaren"                # a projected path is a stored key too

  for f in (_alloc_getproperty, _alloc_getindex, _alloc_haskey, _alloc_get, _alloc_getcolumn, _alloc_path)
    f(row)                                                   # compile
    @test f(row) == 0
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A miss answers as before the fast path (#1592)
# Each of these keys is absent from the row, so it reaches `_normalize_row_symbol` and the
# branches after it. The fast path must not have swallowed a single refusal or alias: `row.a__`
# and `row[:a__]` still raise the empty-segment `UnknownFieldError`; `.pk` still resolves to the
# declared primary key; an unprojected foreign key still raises `LazyTraversalError`, naming the
# field; an unknown name still raises `UnknownFieldError`; `haskey`/`get` on a valid but absent key
# still answer `false` / the default, and on an empty segment still refuse.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a miss answers as before the fast path (#1592)" begin
  row = _senna()

  # The empty-segment refusal, on every read form.
  for read in (r -> r.a__, r -> r[:a__], r -> r["a__"], r -> r[Symbol("__a")],
               r -> haskey(r, :a__), r -> get(r, :a__, nothing), r -> Tables.getcolumn(r, :a__))
    err = try read(row); nothing catch e; e end
    @test err isa UnknownFieldError
    @test occursin("Empty '__' path segment", sprint(showerror, err))
  end

  # The virtual `.pk` alias, reached only on a miss (the row stores no `pk` column).
  @test !haskey(PormG.QueryBuilder.getfield(row, :_data), :pk)
  @test row.pk == 1

  # The many-to-many accessor, reached only on a miss.
  @test !haskey(PormG.QueryBuilder.getfield(row, :_data), :teams)
  @test row.teams isa PormG.QueryBuilder.ManyToManyManager

  # An unprojected foreign key: the lazy-traversal refusal, naming the field and the fix.
  @test !haskey(PormG.QueryBuilder.getfield(row, :_data), :constructorid)
  err = try row.constructorid; nothing catch e; e end
  @test err isa LazyTraversalError
  @test occursin("constructorid", sprint(showerror, err))
  @test occursin("ForeignKey", sprint(showerror, err))

  # An unknown name.
  err = try row.forename; nothing catch e; e end
  @test err isa UnknownFieldError
  @test occursin("has no field or accessor 'forename'", sprint(showerror, err))
  @test_throws KeyError row[:forename]
  @test_throws KeyError Tables.getcolumn(row, :forename)

  # haskey / get on a valid but absent key.
  @test !haskey(row, :forename) && !haskey(row, "forename")
  @test get(row, :forename, :none) === :none
  @test get(row, "forename", :none) === :none
end
