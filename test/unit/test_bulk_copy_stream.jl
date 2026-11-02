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
using Dates, UUIDs, Random
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

# The writer alone, on cells no F1 column above produces but a formatter can hand it: integers of
# every width and both extremes (`format_number_sql` returns an integer as given), `Bool`, text that
# is not a `String` (a `SubString`; any `AbstractString` passes `format_text_sql` unchanged, such as
# a `CSV.File` column's inline strings — `Test.GenericString` stands in for them), invalid UTF-8, and
# a `"` at either end. The expected bytes were taken from `CSV.write(io, cols; header = false,
# quotestrings = true, missingstring = "\N")` directly (CSV 1.2), during phase 5's review.
const BCS1344_WRITER_COLUMNS = (
  Any[Int8(-128), UInt8(255), typemin(Int64), typemax(Int128), big(2)^70, true, UInt64(0), Int16(-10)],
  Any[SubString("xSennax", 2, 6), "\xff\"", "a\xc0\"b", "lone\rCR", missing, "\"\"", "ends\"", "\"starts"],
  Any[Test.GenericString("Räikkönen \"Kimi\""), Test.GenericString(""), "", "\\N", Int32(-7), "😀,\"", missing, "x"],
)
const BCS1344_WRITER_EXPECTED =
  "-128,\"Senna\",\"Räikkönen \"\"Kimi\"\"\"\n" *
  "255,\"\xff\"\"\",\"\"\n" *
  "-9223372036854775808,\"a\xc0\"\"b\",\"\"\n" *
  "170141183460469231731687303715884105727,\"lone\rCR\",\"\\N\"\n" *
  "1180591620717411303424,\\N,-7\n" *
  "true,\"\"\"\"\"\",\"😀,\"\"\"\n" *
  "0,\"ends\"\"\",\\N\n" *
  "-10,\"\"\"starts\",\"x\"\n"

@testset "bulk_copy's writer: integer widths, text types and invalid UTF-8, as CSV.write wrote them (#1344 phase 5)" begin
  @test PormG.QueryBuilder._copy_csv_chunk(BCS1344_WRITER_COLUMNS, 8) == BCS1344_WRITER_EXPECTED
  # A type no formatter returns has no method: it fails by name rather than having its text guessed.
  @test_throws MethodError PormG.QueryBuilder._copy_csv_chunk((Any[1.5],), 1)
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

# ── #1541: the writer against the phase 5 writer, on random chunks ──
# #1541 replaced phase 5's writer (each column into an `IOBuffer`) with one that writes the cells
# straight into a byte vector. The reference below is the phase 5 writer, copied verbatim apart from
# the names: it produced `BCS1344_WRITER_EXPECTED` above, and it is kept here as the oracle the
# random chunks are checked against, since no fixed list of cells covers every width, type and byte
# a formatter can hand the writer.
bcs1541_cell!(io::IO, ::Union{Missing, Nothing}, ::Vector{UInt8}) = (write(io, "\\N"); nothing)
bcs1541_cell!(io::IO, value::Bool, ::Vector{UInt8}) = (write(io, value ? "true" : "false"); nothing)
bcs1541_cell!(io::IO, value::Integer, ::Vector{UInt8}) = (print(io, value); nothing)
function bcs1541_cell!(io::IO, value::Base.BitInteger, digits::Vector{UInt8})
  n = value < 0 ? -unsigned(value) : unsigned(value)
  k = length(digits)
  while true
    digits[k] = UInt8('0') + (rem(n, oftype(n, 10)) % UInt8)
    n = div(n, oftype(n, 10))
    iszero(n) && break
    k -= 1
  end
  value < 0 && write(io, UInt8('-'))
  write(io, view(digits, k:length(digits)))
  return nothing
end
function bcs1541_cell!(io::IO, value::AbstractString, ::Vector{UInt8})
  write(io, '"')
  start = firstindex(value)
  while (q = findnext(==('"'), value, start)) !== nothing
    write(io, SubString(value, start, q), '"')
    start = nextind(value, q)
  end
  write(io, SubString(value, start), '"')
  return nothing
end
function bcs1541_column(column::AbstractVector, nrows::Int)
  io = IOBuffer()
  ends = Vector{Int}(undef, nrows)
  digits = Vector{UInt8}(undef, 40)
  for row in 1:nrows
    bcs1541_cell!(io, column[row], digits)
    ends[row] = position(io)
  end
  return take!(io), ends
end
function bcs1541_reference_chunk(columns, nrows::Int)::String
  written = Tuple{Vector{UInt8}, Vector{Int}}[bcs1541_column(column, nrows) for column in columns]
  out = IOBuffer()
  starts = zeros(Int, length(written))
  for row in 1:nrows
    for (j, (bytes, ends)) in enumerate(written)
      j > 1 && write(out, UInt8(','))
      stop = ends[row]
      write(out, view(bytes, (starts[j] + 1):stop))
      starts[j] = stop
    end
    write(out, UInt8('\n'))
  end
  return String(take!(out))
end

# Text built from the pieces that matter to CSV and to the byte walk: `"` alone and doubled, the
# NULL marker's two characters, every line break, a comma, a backslash, multi-byte UTF-8, and bytes
# that are not UTF-8 (a lone continuation byte, an overlong lead, a truncated sequence, 0xff).
const BCS1541_PIECES = ["\"", "\"\"", "\\N", "\n", "\r\n", "\r", ",", "\\", "Senna", "Räikkönen",
  "😀", " ", "", "\x80", "\xc0", "\xe2\x82", "\xff", "a\xc0\"b"]
bcs1541_text(rng) = join(rand(rng, BCS1541_PIECES, rand(rng, 0:6)))
const BCS1541_INT_TYPES = (Int8, Int16, Int32, Int64, Int128, UInt8, UInt16, UInt32, UInt64, UInt128)
# An integer of type `T` near an edge: an extreme, zero, one, or a power of ten and its neighbours
# (where the digit count changes), else anywhere in the range.
function bcs1541_int(rng, ::Type{T}) where {T}
  r = rand(rng)
  r < 0.15 && return rand(rng, (typemin(T), typemax(T), zero(T), one(T)))
  if r < 0.5
    p = T(10)^rand(rng, 0:(ndigits(typemax(T)) - 1))
    return rand(rng, (p, p - one(T), T <: Signed ? -p : p))
  end
  return rand(rng, T)
end

# One random column of `nrows` cells: a kind, NULLs as `missing` or `nothing` at a random rate, and
# either an `Any` vector (a dynamic dispatch per cell) or the narrowest element type, concrete or a
# small `Union`, which is what a formatter's `map` gives.
function bcs1541_column_of(rng, nrows::Int)
  kind = rand(rng, 1:6)
  cell = if kind == 1
    T = rand(rng, BCS1541_INT_TYPES)
    () -> bcs1541_int(rng, T)
  elseif kind == 2
    () -> rand(rng, (big(2)^130, -big(10)^40, big(0), big(-1)))
  elseif kind == 3
    () -> rand(rng, Bool)
  elseif kind == 4
    () -> bcs1541_text(rng)
  elseif kind == 5
    () -> (s = "x" * bcs1541_text(rng) * "x"; SubString(s, 2, prevind(s, lastindex(s))))
  else
    () -> Test.GenericString(bcs1541_text(rng))
  end
  null_rate = rand(rng, (0.0, 0.0, 0.2, 1.0))
  values = Any[rand(rng) < null_rate ? rand(rng, (missing, nothing)) : cell() for _ in 1:nrows]
  return rand(rng, Bool) ? values : identity.(values)
end

@testset "bulk_copy's writer: random chunks give the phase 5 writer's bytes (#1541)" begin
  # What: 300 seeded random chunks of 0–70 columns and 0–40 rows, every machine-integer width at its
  # edges, `BigInt`, `Bool`, and text as `String`, `SubString` and `GenericString` carrying `"`,
  # `\N`, line breaks and invalid UTF-8, with `missing`/`nothing` cells, in concrete, `Union` and
  # `Any` vectors. Expected: `_copy_csv_chunk` returns exactly the bytes of the phase 5 writer kept
  # above. Why: the byte-vector writer (#1541) is a speed change only; a differing byte would be a
  # different value stored by COPY.
  rng = Random.Xoshiro(1541)
  for _ in 1:300
    nrows = rand(rng, 0:40)
    # An `AbstractVector` of columns, as `bulk_copy` passes them: a tuple would compile both writers
    # once per random tuple of column types.
    columns = AbstractVector[bcs1541_column_of(rng, nrows) for _ in 1:rand(rng, 0:70)]
    expected = bcs1541_reference_chunk(columns, nrows)
    got = PormG.QueryBuilder._copy_csv_chunk(columns, nrows)
    @test got == expected
    got == expected || break   # one failing chunk is enough to read
  end
end

@testset "bulk_copy's writer: each cell's reserve covers the bytes it writes (#1541)" begin
  # What: every cell method, called on an EMPTY buffer, so its `_copy_csv_reserve!` grows the buffer
  # to exactly the bytes it asked for, with the cells that need the most per input: text of nothing
  # but `"` (each doubled), every machine integer's extremes, a negative `BigInt`, `Bool`, NULL.
  # Expected: the end position it returns is within the buffer, and the bytes are the phase 5
  # writer's. Why: the reserve is what makes the cell's `@inbounds` writes safe, and the random
  # chunks cannot see a text reserve one byte short, since the column buffer's first size and its
  # doubling leave slack; here there is none, so a short reserve returns a position past the end,
  # with or without bounds checking.
  cell! = PormG.QueryBuilder._copy_csv_cell!
  quotes = [repeat("\"", n) for n in (0, 1, 2, 3, 15)]
  cells = Any[missing, nothing, true, false, big(2)^130, -big(10)^40,
    quotes..., (SubString("x" * q * "x", 2, 1 + length(q)) for q in quotes)...,
    (Test.GenericString(q) for q in quotes)...]
  for T in BCS1541_INT_TYPES
    append!(cells, T <: Signed ? (typemin(T), typemax(T), zero(T), -one(T)) : (typemax(T), zero(T)))
  end
  for v in cells
    buf = UInt8[]
    p = cell!(buf, 0, v)
    @test p <= length(buf)
    @test String(buf[1:min(p, length(buf))]) == bcs1541_reference_chunk(Any[Any[v]], 1)[1:end-1]
  end
end

# A string type whose code units are bytes but not UTF-8: one byte per character, Latin-1.
struct BCS1541Latin1 <: AbstractString
  data::Vector{UInt8}
end
Base.ncodeunits(s::BCS1541Latin1) = length(s.data)
Base.codeunit(::BCS1541Latin1) = UInt8
Base.codeunit(s::BCS1541Latin1, i::Integer) = s.data[i]
Base.isvalid(s::BCS1541Latin1, i::Integer) = checkbounds(Bool, s.data, i)
Base.iterate(s::BCS1541Latin1, i::Int = 1) = i > length(s.data) ? nothing : (Char(s.data[i]), i + 1)

@testset "bulk_copy's writer: a string type that is not UTF-8 is written as its characters (#1541)" begin
  # What: a Latin-1 string type, whose `ä` is the single code unit 0xe4. Expected: the cell is the
  # UTF-8 text `"Rä"""` (`ä` as 0xc3 0xa4), what the phase 5 writer's `write` gave. Why: copying
  # such a type's code units would send PostgreSQL the byte 0xe4, invalid UTF-8 in place of `ä`; only
  # `String`'s code units are walked as bytes.
  s = BCS1541Latin1(UInt8[0x52, 0xe4, 0x22])
  @test PormG.QueryBuilder._copy_csv_chunk((Any[s],), 1) == "\"R\xc3\xa4\"\"\"\n"
end
