"""
`_query_select` prints the projection list into the caller's buffer (#1594).

It used to push an interpolated `String` per projection into a `Vector{Any}`, `join` them, and hand
the result to `query()`, which printed it into its own `IOBuffer`, so the list was built twice. Now it
prints straight into the caller's buffer, and the two callers that splice the list into a statement
of their own (`exists()`, `count()`) use the `String`-returning method.

The rendered text must not change by a byte. A differential over the whole unit suite (37,112 lists)
checked that once, against the old body; this file pins the shapes the suite's own SQL assertions do
not reach on their own: an empty list, a gap in the list, and each `AS` arm side by side. The SQL in
each `@test` is the projection list `SELECT … FROM` carries, for example

    "Tb"."surname" as "surname",
      COUNT("Tb"."raceid") as "n"

Hermetic: `SQLField`s built by hand; the connection argument is not read for a projection alias.
"""

using Test
using PormG
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))

const _QS = PormG.QueryBuilder
_qs_field(text; as = nothing, custom = nothing) = _QS.SQLField(text, as, custom, :base, nothing)
_qs_print(array) = (io = IOBuffer(); r = _QS._query_select(io, array, nothing); (r, String(take!(io))))

# ─────────────────────────────────────────────────────────────────────────────
# Each projection shape renders as before (#1594)
# Expected list: `"Tb"."surname" as "surname", \n  "Tb".*, \n  *, \n  COUNT(...) as "n",
# \n  "Tb"."forename" as "given", \n  "Tb"."code"` — the `AS` arm per shape: a path with an alias,
# a wildcard (never aliased: `Tb.* AS *` is invalid SQL), a bare `*`, an expression's own alias, a
# `custom_as` that wins over `_as`, and an unaliased column. It matters because `query()` now prints
# this into the statement's buffer directly; a slip in a separator or an arm is a statement that
# no longer parses, or a column read back under the wrong name.
# ─────────────────────────────────────────────────────────────────────────────
@testset "each projection shape renders as before (#1594)" begin
  array = _QS.SQLTypeField[
    _qs_field("\"Tb\".\"surname\""; as = "surname"),
    _qs_field("\"Tb\".*"; as = "points"),
    _qs_field("*"),
    _qs_field("COUNT(\"Tb\".\"raceid\")"; as = "n"),
    _qs_field("\"Tb\".\"forename\""; as = "forename", custom = "given"),
    _qs_field("\"Tb\".\"code\""; as = ""),
  ]
  expected = "\"Tb\".\"surname\" as \"surname\", \n  \"Tb\".*, \n  *, \n  " *
             "COUNT(\"Tb\".\"raceid\") as \"n\", \n  \"Tb\".\"forename\" as \"given\", \n  \"Tb\".\"code\""
  r, printed = _qs_print(array)
  @test r === nothing
  @test printed == expected
  @test _QS._query_select(array, nothing) == expected           # the String method agrees

  # One projection: no separator.
  @test _qs_print(_QS.SQLTypeField[_qs_field("\"Tb\".\"surname\""; as = "surname")])[2] ==
        "\"Tb\".\"surname\" as \"surname\""
end

# ─────────────────────────────────────────────────────────────────────────────
# An empty list is `*`, and a gap ends the list (#1594)
# Expected: `*` for an empty vector and for one whose first slot is unassigned; for slots 1 and 3
# assigned around an unassigned 2, only slot 1 (`"Tb"."surname" as "surname"`). The gap rule is the
# one the old body had (`get_select_query` sizes `select` to the projection count, #1335, so the
# suite never builds one), and a rewrite that skipped the gap instead would print a projection the
# old code dropped.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an empty list is *, and a gap ends the list (#1594)" begin
  @test _qs_print(_QS.SQLTypeField[])[2] == "*"
  @test _QS._query_select(_QS.SQLTypeField[], nothing) == "*"

  first_unset = Vector{_QS.SQLTypeField}(undef, 2)
  first_unset[2] = _qs_field("\"Tb\".\"code\""; as = "code")
  @test _qs_print(first_unset)[2] == "*"

  gap = Vector{_QS.SQLTypeField}(undef, 3)
  gap[1] = _qs_field("\"Tb\".\"surname\""; as = "surname")
  gap[3] = _qs_field("\"Tb\".\"code\""; as = "code")
  @test _qs_print(gap)[2] == "\"Tb\".\"surname\" as \"surname\""
end

# ─────────────────────────────────────────────────────────────────────────────
# The list prints into the caller's buffer, after what it already holds (#1594)
# Expected: `SELECT\n    "Tb"."surname" as "surname"` — the text `query()` writes before the list
# stays, and the list follows it. It matters because the point of the change is that `query()` no
# longer builds the list as a separate string; a method that replaced the buffer's content, or
# returned the text instead of printing it, would drop the `SELECT`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the list prints into the caller's buffer (#1594)" begin
  io = IOBuffer()
  print(io, "SELECT\n    ")
  _QS._query_select(io, _QS.SQLTypeField[_qs_field("\"Tb\".\"surname\""; as = "surname")], nothing)
  @test String(take!(io)) == "SELECT\n    \"Tb\".\"surname\" as \"surname\""
end
