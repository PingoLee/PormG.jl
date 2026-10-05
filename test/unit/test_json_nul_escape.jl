"""
A NUL in a `JSONField` value is refused before anything is sent, the same way on every backend (#954).

JSON writes a NUL as the escape `\\u0000`, so no NUL character is ever bound and the #951 checks never
see one. PostgreSQL `jsonb` cannot store that escape either (SQLSTATE 22P05), so a `create`, a
`@jcontains` filter or a `get_or_create` failed on the server as a `StatementError`, under LibPQ and
Postgres.jl alike, while SQLite stored it. `format_json_sql` now refuses it, and the write path names
the field.

Pinned here, with no server:

  1. **The detector** reads the serialized text, and counts the escape only when an even number of
     backslashes precede it: `"\\\\u0000"` in JSON is a backslash followed by the text `u0000`.
  2. **`format_json_sql`** refuses a NUL in a value, a key, a nested vector, a `NamedTuple` and a
     JSON string the caller serialized, and never echoes the value.
  3. **A real SQLite database** — every writer refuses, naming the field (and the row, for a bulk
     write), and nothing is written; a legitimate backslash-`u0000` text still round-trips.
  4. **A PostgreSQL mock** — `create`, a `@jcontains` filter and `get_or_create` are refused before the
     driver is called.

julia --project=test/integration test/unit/test_json_nul_escape.jl
"""

using Test
using DataFrames
using PormG
# Standalone runs need the SQLite extension for the real-engine half (runtests.jl loads it too).
include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using PormG.Models: Model, IDField, CharField, JSONField, format_json_sql, _json_has_nul_escape
using PormG.QueryBuilder: bulk_insert, bulk_update
import PormG.ConnectionPool: fetch, SQLiteConnectionPool

const NUL954 = Dict("note" => "box\0secret")     # the text after the NUL must never appear in a message
json954_refused(f) = try f(); nothing catch e e end
# A refusal of this issue's kind, not some other `InvalidValueError`, and no value in the message.
is_json_nul_refusal(e) = e isa PormG.InvalidValueError && occursin("written \\u0000 in JSON", e.msg) &&
  !occursin("secret", e.msg)

# ─────────────────────────────────────────────────────────────────────────────
# The detector: an escape preceded by an even number of backslashes
# In JSON text `\\` is one literal backslash, so `\\u0000` is a backslash plus the text `u0000`
# (legitimate), while `\\\u0000` is a backslash plus a NUL (refused). Raw strings keep the backslashes
# exactly as they appear in the serialized document.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#954: _json_has_nul_escape — the escape, not an escaped backslash" begin
  @test _json_has_nul_escape(raw"""{"a":"\u0000"}""")
  @test _json_has_nul_escape(raw"""{"a":"box\u0000box"}""")
  @test _json_has_nul_escape(raw"""{"\u0000":1}""")             # in a key
  @test _json_has_nul_escape(raw"""["\\\u0000"]""")             # backslash, then a NUL
  @test _json_has_nul_escape(raw"""["\\\\\\\u0000"]""")         # three backslashes, then a NUL
  @test _json_has_nul_escape(raw"""{"a":"\u00000"}""")          # a NUL, then the digit 0

  @test !_json_has_nul_escape(raw"""{"a":"\\u0000"}""")         # backslash + the text u0000
  @test !_json_has_nul_escape(raw"""{"a":"\\\\u0000"}""")       # two backslashes + the text
  @test !_json_has_nul_escape(raw"""{"a":"u0000"}""")
  @test !_json_has_nul_escape(raw"""{"a":"\u0001"}""")          # other control characters pass
end

# ─────────────────────────────────────────────────────────────────────────────
# format_json_sql: every shape that serializes a NUL is refused, nothing else changes
# The formatter is the one funnel every JSON value passes — writes, a document filter, a default —
# so the refusal lives there. Clean values come back exactly as before.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#954: format_json_sql refuses a NUL in any position" begin
  @test is_json_nul_refusal(json954_refused(() -> format_json_sql(NUL954)))
  @test is_json_nul_refusal(json954_refused(() -> format_json_sql(Dict("k\0secret" => 1))))
  @test is_json_nul_refusal(json954_refused(() -> format_json_sql(["ok", ["box\0secret"]])))
  @test is_json_nul_refusal(json954_refused(() -> format_json_sql((lap = 1, note = "box\0secret"))))
  # A JSON document the caller serialized: the escape is in the text they passed.
  @test is_json_nul_refusal(json954_refused(() -> format_json_sql(raw"""{"note":"box\u0000secret"}""")))

  # Unchanged: clean values, and the legitimate six-character text `\u0000`.
  @test format_json_sql(Dict("note" => "box")) == """{"note":"box"}"""
  @test format_json_sql(Dict("path" => "C:\\u0000")) == raw"""{"path":"C:\\u0000"}"""
  @test format_json_sql(raw"""{"path":"\\u0000"}""") == raw"""{"path":"\\u0000"}"""
  @test format_json_sql(missing) === missing
  @test format_json_sql(15) == "15"

  # A `default=` is checked when the model is defined, with the same reason — for a collection too,
  # which used to be reported as a type mismatch.
  for d in (NUL954, raw"""{"note":"box\u0000secret"}""")
    e = json954_refused(() -> JSONField(default = d))
    @test e isa PormG.FieldValidationError
    @test occursin("written \\u0000 in JSON", e.msg) && !occursin("secret", e.msg)
  end
  @test JSONField(default = Dict("lap" => 12)).default == """{"lap":12}"""
  # Any other collection `JSON.json` cannot write keeps its pre-#954 report — a FieldValidationError,
  # never the serializer's raw `ArgumentError`.
  e = json954_refused(() -> JSONField(default = [NaN]))
  @test e isa PormG.FieldValidationError && occursin("Expected type", e.msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# A real SQLite database: every writer refuses, names the field, writes nothing
# SQLite is the backend that could store the escape, and refuses it anyway so the engines agree. The
# table proves nothing was written; the legitimate backslash text proves the detector is not
# over-eager on a real round trip.
# ─────────────────────────────────────────────────────────────────────────────
function json954_with_sqlite(f)
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "json954.sqlite"); pool_size = 1)
    key = "json954_sqlite"
    PormG.config[key] = PormG.Configuration.Settings(connections = pool, db_def_folder = dir, change_data = true)
    try
      fetch(pool, "CREATE TABLE json954_pit_stop (id INTEGER PRIMARY KEY, telemetry TEXT);")
      fetch(pool, """INSERT INTO json954_pit_stop (id, telemetry) VALUES (1, '{"lap":12}');""")
      model = Model("json954_pit_stop", id = IDField(), telemetry = JSONField(null = true))
      model.connect_key = key
      f(pool, model)
    finally
      delete!(PormG.config, key)
      PormG.ConnectionPool.close_pool!(pool)   # release the handle so mktempdir can clean up (Windows)
    end
  end
end

json954_rows(pool) = [(r.id, r.telemetry) for r in fetch(pool, "SELECT id, telemetry FROM json954_pit_stop ORDER BY id;")]

@testset "#954: SQLite — every writer refuses a JSON NUL, naming the field, and writes nothing" begin
  json954_with_sqlite() do pool, model
    seeded = json954_rows(pool)
    # Each writer, with the field named in #951's wording so one message covers text and JSON.
    for (op, call) in (("insert", () -> model.objects.create("id" => 2, "telemetry" => NUL954)),
                       ("insert", () -> model.objects.create("id" => 2, "telemetry" => raw"""{"n":"\u0000"}""")),
                       ("update", () -> model.objects.filter("id" => 1).update("telemetry" => NUL954)),
                       ("get_or_create", () -> model.objects.get_or_create("telemetry" => NUL954)))
      e = json954_refused(call)
      @test is_json_nul_refusal(e)
      @test occursin("Error in $op, field `telemetry` contains a NUL", e.msg)
    end
    # Bulk writers name the row too — and must not fall through to the generic "can't be formatted"
    # message, which prints the value.
    e = json954_refused(() -> bulk_insert(model.objects, DataFrame(id = [2, 3], telemetry = [Dict("lap" => 1), NUL954])))
    @test is_json_nul_refusal(e) && occursin("row 2", e.msg) && occursin("field `telemetry`", e.msg)
    e = json954_refused(() -> bulk_update(model.objects, DataFrame(id = [1], telemetry = [NUL954])))
    @test is_json_nul_refusal(e) && occursin("row 1", e.msg) && occursin("field `telemetry`", e.msg)
    @test json954_rows(pool) == seeded

    # A JSON *string* on the filter path: a plain filter, an `@in` list, and `get_or_create`, whose
    # lookup filters before it formats a write. The filter path converts a formatter's
    # `InvalidValueError` into a `FilterError` that prints the value, so this refusal is passed
    # through it named instead — never echoing the text after the NUL.
    nul_text = raw"""{"note":"box\u0000secret"}"""
    for call in (() -> model.objects.filter("telemetry" => nul_text).list(),
                 () -> model.objects.filter("telemetry__@in" => [nul_text]).list(),
                 () -> model.objects.get_or_create("telemetry" => nul_text))
      e = json954_refused(call)
      @test is_json_nul_refusal(e)
      @test occursin("Error in filter, field `telemetry` contains a NUL", e.msg)
    end
    @test json954_rows(pool) == seeded

    # The legitimate text `\u0000` (a backslash, then `u0000`) is written and read back intact.
    model.objects.create("id" => 2, "telemetry" => Dict("path" => "C:\\u0000"))
    @test json954_rows(pool)[end] == (2, raw"""{"path":"C:\\u0000"}""")
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL mock: nothing reaches the driver
# PostgreSQL is where the escape failed, on the server. The mock records every statement handed to the
# driver and fails, so a zero count proves the refusal came first. Calls run inside `with_tx_context`,
# standing in for `run_in_transaction`: the mock has no connection to acquire.
# ─────────────────────────────────────────────────────────────────────────────
struct Json954MockPg <: PormG.PormGPostgres end
PormG.config["json954_pg"] = PormG.Configuration.Settings(connections = Json954MockPg(), change_data = true)

const JSON954_SENT = String[]
struct Json954Reached <: Exception end
function PormG.backend_execute_async(::Json954MockPg, conn, sql::String, params)
  push!(JSON954_SENT, sql)
  throw(Json954Reached())
end

const JSON954_PG = Model("json954_pit_stop", id = IDField(), code = CharField(max_length = 20, null = true),
                         telemetry = JSONField(null = true))
JSON954_PG.connect_key = "json954_pg"

function json954_pg(f)
  empty!(JSON954_SENT)
  try
    PormG.Configuration.with_tx_context(f, PormG.config["json954_pg"].connections, :mock_tx_conn)
    nothing
  catch e
    e
  end
end

@testset "#954: PostgreSQL — a JSON NUL is refused before the driver is called" begin
  # The control: a clean document does reach the driver, so a zero count below means "refused".
  e = json954_pg(() -> JSON954_PG.objects.filter("telemetry__@jcontains" => Dict("note" => "box")).list())
  @test !(e isa PormG.InvalidValueError)   # the mock driver's own failure, wrapped as a StatementError
  @test length(JSON954_SENT) == 1

  e = json954_pg(() -> JSON954_PG.objects.create("id" => 2, "telemetry" => NUL954))
  @test is_json_nul_refusal(e) && isempty(JSON954_SENT)
  e = json954_pg(() -> JSON954_PG.objects.filter("telemetry__@jcontains" => NUL954).list())
  @test is_json_nul_refusal(e) && isempty(JSON954_SENT)
  e = json954_pg(() -> JSON954_PG.objects.get_or_create("telemetry" => NUL954))
  @test is_json_nul_refusal(e) && isempty(JSON954_SENT)
  # A JSON string on the filter path, as on SQLite above.
  e = json954_pg(() -> JSON954_PG.objects.filter("telemetry" => raw"""{"note":"box\u0000secret"}""").list())
  @test is_json_nul_refusal(e) && isempty(JSON954_SENT)
end
