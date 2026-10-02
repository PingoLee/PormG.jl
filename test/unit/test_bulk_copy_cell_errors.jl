# ============================================================
# test/unit/test_bulk_copy_cell_errors.jl
#
# #869 — a value `bulk_copy` refuses names the cell it came from.
#
# CONTRACT being tested:
#   `bulk_copy` validates and formats each cell inside a `try`. A refused value raises
#   `InvalidValueError` whose message names the row index, the model and the field, followed by the
#   reason, each said once:
#     "Error in bulk_copy, row 3 for model <name>, field \"<field>\": <reason>"
#   This holds for every source of the refusal: a formatter's typed error (`format_text_sql` on a
#   float) and a `_validation_error` (a max_length, #868). The collection refusal (#712) keeps its
#   own field wording after the same head: "…, row 3 for model <name>, field `<field>` was given …".
#   An untyped error is wrapped the same way; any other `PormGError` passes through untouched.
#
#   Before #869 only an untyped error got the row index. A typed refusal is a `PormGError`, so it
#   was rethrown bare: a float in a text column of a 100k-row frame reported
#   "A text value must be a String, …" with no row, no field and no model.
#
# Hermetic: a mock PostgreSQL pool (bulk_copy is PostgreSQL-only), run inside `with_tx_context` as
# `test_bulk_row_counts.jl` does. Every refusal fires while the chunk is formatted, before the COPY
# statement reaches the driver, so no driver call is scripted.
# ============================================================

using Test
using DataFrames
using PormG
using PormG.Models: Model, CharField, IDField, IntegerField
using PormG.QueryBuilder: bulk_copy

struct BulkCopyCellErrorsMockPg <: PormG.PormGPostgres end
PormG.config["bcce869_pg"] = PormG.Configuration.Settings(
  connections = BulkCopyCellErrorsMockPg(), change_data = true)

# F1 results: `code` is a three-letter driver code, so it carries the bounded text column.
const BCCE869_RESULT = Model("bcce869_result",
  id = IDField(), code = CharField(max_length = 3), year = IntegerField())
BCCE869_RESULT.connect_key = "bcce869_pg"

# Run `bulk_copy` on the mock pool, as if inside `run_in_transaction`, and return the exception it
# raised, or `nothing`, so a missing refusal fails the `isa` test rather than aborting the file.
# The outer `catch` in bulk_copy logs the failure with `@error` before rethrowing; that log is part
# of the contract, so it is asserted rather than silenced. The `try` sits INSIDE `@test_logs`, which
# does not catch: a body that throws would skip the log assertion instead of checking it.
function bcce869_refusal(df, model = BCCE869_RESULT)
  @test_logs (:error, "Error in bulk_copy") match_mode = :any try
    PormG.Configuration.with_tx_context(PormG.config["bcce869_pg"].connections, :mock_tx_conn) do
      bulk_copy(model.objects, df)
    end
    nothing
  catch e
    e
  end
end

# A season frame whose third row carries the bad cell in `column`; rows 1 and 2 are valid, so the
# reported row is the one that failed, not the first one formatted.
function bcce869_frame(column::Symbol, bad)
  codes = Any["SEN", "PRO", "MAN"]
  years = Any[1988, 1988, 1988]
  column === :code ? (codes[3] = bad) : (years[3] = bad)
  return DataFrame(code = codes, year = years)
end

bcce869_msg(err) = err === nothing ? "" : sprint(showerror, err)

# ─────────────────────────────────────────────────────────────────────────────
# Every refusal source: the message names row 3, the model and the field, and keeps the reason.
# Each row is one source the cell `try` can raise from. `reason` is a fragment of that source's own
# text, so the wrapping is shown to carry it rather than replace it. `named` is how the field is
# named: the collection refusal keeps `_single_value`'s own backticked wording, which #712 pins for
# every writer (`test_single_row_collection_value.jl`); the rest are named as `_validation_error` does.
# ─────────────────────────────────────────────────────────────────────────────
const BCCE869_CASES = (
  (source = "format_text_sql refuses a float", column = :code, bad = 1.5,
   reason = "A text value must be a String", named = "field \"code\""),
  (source = "max_length on an integer written as text (#868)", column = :code, bad = 12345,
   reason = "max_length is 3", named = "field \"code\""),
  (source = "max_length on a String", column = :code, bad = "SENNA",
   reason = "max_length is 3", named = "field \"code\""),
  (source = "an integer field refuses text", column = :year, bad = "nineteen",
   reason = "expected", named = "field \"year\""),
  (source = "a collection in one cell", column = :code, bad = ["A", "B"],
   reason = "a column holds a single value", named = "field `code`"),
)

@testset "#869: a bulk_copy refusal names the row, model and field" begin
  for c in BCCE869_CASES
    @testset "$(c.source)" begin
      err = bcce869_refusal(bcce869_frame(c.column, c.bad))
      # The taxonomy type is kept: callers catch `InvalidValueError`, as before #869.
      @test err isa PormG.InvalidValueError
      msg = bcce869_msg(err)
      @test occursin("row 3", msg)
      @test occursin("model bcce869_result", msg)
      @test occursin(c.named, msg)
      @test occursin(c.reason, msg)
      # Said once: the wrapped `_validation_error` / `_single_value` prefix is dropped, not nested.
      @test count("Error in bulk_copy", msg) == 1
      @test count("bcce869_result", msg) == 1
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The two other arms of the cell `catch`, driven through a field whose formatter is swapped for one
# that raises the error under test. An untyped error still becomes `InvalidValueError` and now also
# names the field; any other `PormGError` is not about the value, so it passes through as raised —
# neither re-typed nor re-worded.
# ─────────────────────────────────────────────────────────────────────────────
const BCCE869_HOOKED = Model("bcce869_hooked", id = IDField(), code = CharField(max_length = 3))
BCCE869_HOOKED.connect_key = "bcce869_pg"

# The refusal `bulk_copy` raises for a one-row frame when `code`'s formatter throws `thrown`.
function bcce869_hooked_refusal(thrown)
  BCCE869_HOOKED.fields["code"].formatter = _ -> throw(thrown)
  return bcce869_refusal(DataFrame(code = ["SEN"]), BCCE869_HOOKED)
end

@testset "#869: an untyped cell error names the cell; another PormGError passes as is" begin
  err = bcce869_hooked_refusal(ErrorException("formatter exploded"))
  @test err isa PormG.InvalidValueError
  msg = bcce869_msg(err)
  @test occursin("row 1", msg)
  @test occursin("model bcce869_hooked", msg)
  @test occursin("field \"code\"", msg)
  @test occursin("formatter exploded", msg)

  # The very object raised, untouched: not wrapped into an `InvalidValueError`.
  capability = PormG.BackendCapabilityError("not on this backend")
  @test bcce869_hooked_refusal(capability) === capability
end
