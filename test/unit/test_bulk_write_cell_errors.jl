# ============================================================
# test/unit/test_bulk_write_cell_errors.jl
#
# #875 — a value `bulk_insert` or `bulk_update` refuses in VALIDATION names the cell it came from.
#
# CONTRACT being tested:
#   Both writers validate each row inside a `try`. A validation refusal — a max_length, a decimal
#   width — raises `InvalidValueError` whose message names the row index,
#   the model and the field, followed by the reason, each said once:
#     "Error in bulk_insert, row 3 for model <name>, field \"<field>\": <reason>"
#   the same shape #869 gave `bulk_copy` (one shared helper, `_bulk_cell_error`).
#
#   A FORMATTER refusal keeps its own route: the writers' depuration pass re-runs each formatter and
#   reports "… the field <f> (col: <c>) in row 3 has a value that can't be formatted …", as before.
#
#   Before #875 the depuration pass found nothing for a validation refusal (every formatter accepts
#   `"SENNA"`), so the error was rethrown bare: "Error in bulk_insert for model …, field \"code\":
#   max_length is 3 …", with no row — nothing located the bad cell in a 100k-row frame.
#
# Hermetic: mock PostgreSQL and SQLite pools, `show_query = :dict`. Every refusal fires while the
# row is validated, before a statement is built, so no driver call is made. Validation is the same
# on both engines; both are run because each writer builds its rows differently per engine (#672).
# ============================================================

using Test
using DataFrames
using PormG
using PormG.Models: Model, CharField, DecimalField, IDField, IntegerField
using PormG.QueryBuilder: bulk_insert, bulk_update

struct BulkWriteCellErrorsMockPg <: PormG.PormGPostgres end
struct BulkWriteCellErrorsMockSl <: PormG.PormGSQLite end
# The SQLite chunk cap reads the library version for its bind-parameter limit; a modern build.
PormG.backend_sqlite_version(::BulkWriteCellErrorsMockSl) = 3045000
PormG.config["bwce875_pg"] = PormG.Configuration.Settings(connections = BulkWriteCellErrorsMockPg(), change_data = true)
PormG.config["bwce875_sl"] = PormG.Configuration.Settings(connections = BulkWriteCellErrorsMockSl(), change_data = true)

# F1 results: `code` is a three-letter driver code (the bounded text column), `points` a decimal
# with at most two digits before the point.
bwce875_result(key) = begin
  m = Model("bwce875_result",
    id = IDField(), code = CharField(max_length = 3), year = IntegerField(),
    points = DecimalField(max_digits = 3, decimal_places = 1))
  m.connect_key = key
  m
end
const BWCE875_MODELS = (pg = bwce875_result("bwce875_pg"), sl = bwce875_result("bwce875_sl"))

# A season frame whose third row carries the bad cell in `column`; rows 1 and 2 are valid, so the
# reported row is the one that failed, not the first one validated.
function bwce875_frame(column::Symbol, bad)
  cols = Dict{Symbol, Vector{Any}}(
    :code => Any["SEN", "PRO", "MAN"], :year => Any[1988, 1988, 1988], :points => Any[9.0, 6.0, 4.0])
  cols[column][3] = bad
  return DataFrame(id = [1, 2, 3], code = cols[:code], year = cols[:year], points = cols[:points])
end

# The exception the writer raised, or `nothing`, so a missing refusal fails the `isa` test rather
# than aborting the file.
function bwce875_refusal(writer::Symbol, model, column::Symbol, bad)
  df = bwce875_frame(column, bad)
  try
    if writer === :bulk_insert
      bulk_insert(model.objects, select(df, Not(:id)); show_query = :dict)
    else
      bulk_update(model.objects, df; columns = [String(column)], match_on = ["id"], show_query = :dict)
    end
    nothing
  catch e
    e
  end
end

bwce875_msg(err) = err === nothing ? "" : sprint(showerror, err)

# ─────────────────────────────────────────────────────────────────────────────
# Every validation source: the message names row 3, the model and the field, and keeps the reason.
# `reason` is a fragment of `_validate_field_value`'s own text, so the wrapping is shown to carry it
# rather than replace it.
# ─────────────────────────────────────────────────────────────────────────────
const BWCE875_CASES = (
  (source = "max_length on a String", column = :code, bad = "SENNA", reason = "max_length is 3"),
  (source = "max_length on an integer written as text (#868)", column = :code, bad = 12345, reason = "max_length is 3"),
  (source = "a decimal wider than the column", column = :points, bad = 123.5, reason = "max_digits"),
)

@testset "#875: a bulk validation refusal names the row, model and field" begin
  for (backend, model) in pairs(BWCE875_MODELS), writer in (:bulk_insert, :bulk_update), c in BWCE875_CASES
    @testset "$backend $writer: $(c.source)" begin
      err = bwce875_refusal(writer, model, c.column, c.bad)
      # The taxonomy type is kept: callers catch `InvalidValueError`, as before #875.
      @test err isa PormG.InvalidValueError
      msg = bwce875_msg(err)
      @test occursin("Error in $writer, row 3 for model bwce875_result, field \"$(c.column)\": ", msg)
      @test occursin(c.reason, msg)
      # Said once: the wrapped `_validation_error` prefix is dropped, not nested.
      @test count("Error in $writer", msg) == 1
      @test count("bwce875_result", msg) == 1
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# A formatter refusal is unchanged: the formatter refuses the cell, and the depuration pass names it
# in its own wording. Pinned so the validation wrap above cannot pre-empt it. Two shapes: a float in a
# text field passes validation (`_written_text` has no text for it) and only the formatter refuses
# it; `"nineteen"` in an integer field is refused by both, and the formatter's report wins — it named
# the row before #875, which is why #875's integer example was never the unlocated case.
# ─────────────────────────────────────────────────────────────────────────────
const BWCE875_FORMATTER_CASES = (
  (source = "a float in a text field", column = :code, bad = 1.5, reason = "A text value must be a String"),
  (source = "text in an integer field", column = :year, bad = "nineteen", reason = "is not a valid number"),
)

@testset "#875: a formatter refusal still reports through the depuration pass" begin
  for (backend, model) in pairs(BWCE875_MODELS), writer in (:bulk_insert, :bulk_update), c in BWCE875_FORMATTER_CASES
    @testset "$backend $writer: $(c.source)" begin
      err = bwce875_refusal(writer, model, c.column, c.bad)
      @test err isa PormG.InvalidValueError
      # The depuration message colors the row and field; whether the escapes survive depends on
      # the terminal, so they are stripped before matching across them.
      msg = replace(bwce875_msg(err), r"\e\[[0-9;]*m" => "")
      @test occursin("the field $(c.column) (col: $(c.column)) in row 3 has a value that can't be formatted", msg)
      @test occursin(c.reason, msg)
    end
  end
end
