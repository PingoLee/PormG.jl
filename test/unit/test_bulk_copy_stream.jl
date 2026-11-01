# ============================================================
# test/unit/test_bulk_copy_stream.jl
#
# #1344 phase 5 — the bytes `bulk_copy` sends through PostgreSQL's COPY.
#
# CONTRACT being tested:
#   `bulk_copy` runs `COPY … FROM STDIN WITH (FORMAT CSV, HEADER FALSE, NULL '\N')` and streams one
#   text chunk per 10,000 rows. Each cell has already been validated and formatted by the field
#   (`_format_single`), so a cell is `missing`, an integer, a `Bool` or text, and the stream spells
#   them as:
#     - `missing`  → `\N`, unquoted: the NULL marker (#86);
#     - text       → always quoted, each `"` doubled, so `""` is an empty string and `"\N"` is the
#                    two characters, never NULL; a comma, a newline or a CR inside stays data;
#     - an integer → its digits; a `Bool` → `true` / `false`;
#   cells joined by `,`, every row ended by `\n`.
#
#   The expected stream below was RECORDED from `CSV.write(io, chunk; header = false,
#   quotestrings = true, missingstring = "\N")`, the writer `bulk_copy` used before #1344 phase 5,
#   and committed while that writer was still in place. Phase 5 replaced it with PormG's own; the
#   same bytes are the proof that nothing a COPY stores changed. It is an oracle: a difference is a
#   change in what PostgreSQL stores, and is never fixed by re-recording.
#
# Hermetic: a mock PostgreSQL pool (bulk_copy is PostgreSQL-only) whose `backend_copy_in!` records
# the data it is handed, run inside `with_tx_context` as `test_bulk_row_counts.jl` does.
# ============================================================

using Test
using Dates, UUIDs
using PormG
using PormG.Models: Model, IDField, CharField, TextField, IntegerField, BigIntegerField, FloatField,
  DecimalField, BooleanField, DateField, DateTimeField, TimeField, DurationField, UUIDField,
  JSONField, BinaryField, ArrayField
using PormG.QueryBuilder: bulk_copy

struct BulkCopyStreamMockPg <: PormG.PormGPostgres end
PormG.config["bcs1344_pg"] = PormG.Configuration.Settings(
  connections = BulkCopyStreamMockPg(), change_data = true)

# Each COPY the mock receives: its statement and the chunks of its data, in order.
const BCS1344_COPIES = Tuple{String, Vector{String}}[]
function PormG.backend_copy_in!(::BulkCopyStreamMockPg, conn, sql::String, data_itr)
  chunks = String[String(c) for c in data_itr]
  push!(BCS1344_COPIES, (sql, chunks))
  # The row count COPY's tag would carry, read as lines: right for the chunk-boundary testset, whose
  # cells hold no line break; the byte-for-byte testset does not read it.
  return sum(count(==('\n'), c) for c in chunks; init = 0)
end

function bcs1344_copy(model, table)
  empty!(BCS1344_COPIES)
  r = PormG.Configuration.with_tx_context(PormG.config["bcs1344_pg"].connections, :mock_tx_conn) do
    bulk_copy(model.objects, table)
  end
  return r, copy(BCS1344_COPIES)
end

# One column per kind of value a field formatter hands `bulk_copy`. No key column: a supplied key
# would add the sequence resync, which is not what this file is about. Every field is nullable so a
# row can be all `missing`.
const BCS1344_CELLS = Model("bcs1344_cells",
  id       = IDField(),
  name     = CharField(max_length = 60, null = true),
  note     = TextField(null = true),
  grid     = IntegerField(null = true),
  millis   = BigIntegerField(null = true),
  speed    = FloatField(null = true),
  points   = DecimalField(max_digits = 8, decimal_places = 2, null = true),
  podium   = BooleanField(null = true),
  day      = DateField(null = true),
  started  = DateTimeField(null = true),
  lap_time = TimeField(null = true),
  gap      = DurationField(null = true),
  ref      = UUIDField(null = true),
  meta     = JSONField(null = true),
  blob     = BinaryField(null = true),
  tags     = ArrayField(CharField(max_length = 20), null = true))
BCS1344_CELLS.connect_key = "bcs1344_pg"

# F1-flavoured values chosen for the characters COPY's CSV text treats specially: quotes, commas,
# newlines (LF, CRLF and a bare CR), a backslash, the NULL marker spelled as text, an empty string,
# surrounding spaces and non-ASCII letters; integers at the edges; bytes holding NUL-free binary
# (`0x22` is `"`); an array whose elements carry a quote and a comma.
const BCS1344_ROWS = (
  name     = ["",                         "Räikkönen, \"Kimi\"",            missing,  "  Senna  "],
  note     = ["\\N",                      "lap 1\nlap 2\r\nlap 3\rend",     missing,  "C:\\pit\\box"],
  grid     = [-7,                          0,                                missing,  22],
  millis   = [9223372036854775807,         -9223372036854775807,             missing,  5_690_616],
  speed    = [-1.5,                        1.0e20,                           missing,  218.3],
  points   = ["12.50",                     "0",                              missing,  "-3.25"],
  podium   = [true,                        false,                            missing,  true],
  day      = [Date(2009, 3, 29),           Date(1950, 5, 13),                missing,  Date(2021, 12, 12)],
  started  = [DateTime(2009, 3, 29, 6),    DateTime(1950, 5, 13, 14, 0, 30), missing,  DateTime(2021, 12, 12, 13, 0, 0, 125)],
  lap_time = [Time(0, 1, 38, 109),         Time(14, 30),                     missing,  Time(23, 59, 59)],
  gap      = [Dates.Second(98),            Dates.Millisecond(1500),          missing,  Dates.Minute(2)],
  ref      = [UUID("6f1c3b8e-2a4d-4f5e-9b7a-0c1d2e3f4a5b"), UUID("00000000-0000-0000-0000-000000000000"), missing, UUID("ffffffff-ffff-4fff-bfff-ffffffffffff")],
  meta     = [Dict("team" => "McLaren \"MP4/4\""), Dict("laps" => 61, "wet" => true), missing, Dict("note" => "a,b\nc")],
  blob     = [UInt8[0x01, 0x22, 0xff],     UInt8[0x5c, 0x4e],                missing,  UInt8[]],
  tags     = [["pole \"P1\"", "a,b"],      ["fastest lap"],                  missing,  String[]],
)

# Recorded from the CSV.write writer; see the header. One line per row: the first and fourth carry
# the edge values, the second the quotes and line breaks inside quoted text, the third is all NULL.
const BCS1344_EXPECTED =
  "\"\",\"\\N\",-7,9223372036854775807,\"-1.5\",\"12.50\",true,\"2009-03-29\",\"2009-03-29T06:00:00.000+00:00\",\"00:01:38.109\",\"00:01:38\",\"6f1c3b8e-2a4d-4f5e-9b7a-0c1d2e3f4a5b\",\"{\"\"team\"\":\"\"McLaren \\\"\"MP4/4\\\"\"\"\"}\",\"\\x0122ff\",\"{\"\"pole \\\"\"P1\\\"\"\"\",\"\"a,b\"\"}\"\n" *
  "\"Räikkönen, \"\"Kimi\"\"\",\"lap 1\nlap 2\r\nlap 3\rend\",0,-9223372036854775807,\"1e+20\",\"0\",false,\"1950-05-13\",\"1950-05-13T14:00:30.000+00:00\",\"14:30:00\",\"00:00:01.5\",\"00000000-0000-0000-0000-000000000000\",\"{\"\"laps\"\":61,\"\"wet\"\":true}\",\"\\x5c4e\",\"{\"\"fastest lap\"\"}\"\n" *
  "\\N,\\N,\\N,\\N,\\N,\\N,\\N,\\N,\\N,\\N,\\N,\\N,\\N,\\N,\\N\n" *
  "\"  Senna  \",\"C:\\pit\\box\",22,5690616,\"218.30000000000001\",\"-3.25\",true,\"2021-12-12\",\"2021-12-12T13:00:00.125+00:00\",\"23:59:59\",\"00:02:00\",\"ffffffff-ffff-4fff-bfff-ffffffffffff\",\"{\"\"note\"\":\"\"a,b\\nc\"\"}\",\"\\x\",\"{}\"\n"

@testset "bulk_copy: the COPY stream, byte for byte (#1344 phase 5, #86, #296, #28)" begin
  r, copies = bcs1344_copy(BCS1344_CELLS, BCS1344_ROWS)
  @test length(copies) == 1
  sql, chunks = only(copies)
  @test sql == "COPY \"bcs1344_cells\" (\"name\", \"note\", \"grid\", \"millis\", \"speed\", \"points\", \"podium\", \"day\", \"started\", \"lap_time\", \"gap\", \"ref\", \"meta\", \"blob\", \"tags\") FROM STDIN WITH (FORMAT CSV, HEADER FALSE, NULL '\\N')"
  @test length(chunks) == 1
  @test only(chunks) == BCS1344_EXPECTED
end

# A small table, 10,001 rows: one more than a chunk.
const BCS1344_LAPS = Model("bcs1344_laps",
  id = IDField(), code = CharField(max_length = 3), lap = IntegerField())
BCS1344_LAPS.connect_key = "bcs1344_pg"

@testset "bulk_copy: a chunk boundary sends two COPYs, each ending its last row (#1344 phase 5, #670)" begin
  n = 10_001
  rows = (code = [isodd(i) ? "HAM" : "VER" for i in 1:n], lap = collect(1:n))
  r, copies = bcs1344_copy(BCS1344_LAPS, rows)
  @test length(copies) == 2
  first_chunk, second_chunk = only(copies[1][2]), only(copies[2][2])
  @test count(==('\n'), first_chunk) == 10_000
  @test startswith(first_chunk, "\"HAM\",1\n\"VER\",2\n")
  @test endswith(first_chunk, "\"VER\",10000\n")
  @test second_chunk == "\"HAM\",10001\n"
  @test r == (count = n, rows = nothing)
end
