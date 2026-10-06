"""
A refusal never prints the value it refused (#971).

A bound value can be a password, a token or any other secret, and an app may hand `e.msg` straight to
an HTTP client. #951 and #954 settled that their NUL refusals never print the value; #971 made it the
rule for every refusal and moved the reason into data — `InvalidValueError` carries a `kind`, a
`reason`, and the `op`/`model`/`field`/`row` a funnel attaches once — so no funnel has to re-read a
refusal's text to locate it.

Pinned here, with no server:

  1. **The source scan** — no `InvalidValueError(`, `FilterError(` or `QueryBuildError(` in `src/` or `ext/`
     interpolates a value-shaped name (`value`, `v`, `x`, `raw`, `operand`, `row[…]`, …), a
     `repr(…)`, an exception's own text (`\$(e)`, `sprint(showerror, e)`, `e.msg`). A reviewed
     exception carries `# refusal-value-ok: <why>` on its line.
  2. **The data shape** — the one-string constructor still works (#231's contract), and the location
     a funnel attaches renders once.
  3. **Every path, end to end** — a filter, a write, a bulk write and `sqlite_bind_value`, each fed a
     value carrying a marker, raise `InvalidValueError` with the field (and row) set and no marker
     in `msg` or `error_message`.

julia --project=test/integration test/unit/test_refusal_no_value.jl
"""

using Test
using PormG
using DataFrames
include(joinpath(@__DIR__, "..", "load_drivers.jl"))

const SECRET971 = "s3cr3t971"

# ─────────────────────────────────────────────────────────────────────────────
# 1. Source scan
# ─────────────────────────────────────────────────────────────────────────────
# The names a refusal must never interpolate: the value under every spelling the code base uses for
# it. A type, a field name, a length or an index is fine — `typeof(value)` does not match.
const VALUE_NAMES971 = Set(["value", "values", "v", "x", "s", "text", "el", "raw", "normalized",
                            "operand", "y", "n", "default", "val", "item", "cell"])

# The interpolations inside one string literal span: `$name` and `$(expr)`.
function _interpolations971(src::AbstractString)
  out = String[]
  i = firstindex(src)
  while (j = findnext('$', src, i)) !== nothing
    k = nextind(src, j)
    k > lastindex(src) && break
    if src[k] == '('
      depth, m = 1, nextind(src, k)
      while m <= lastindex(src) && depth > 0
        src[m] == '(' && (depth += 1)
        src[m] == ')' && (depth -= 1)
        depth > 0 && (m = nextind(src, m))
      end
      push!(out, strip(src[nextind(src, k):prevind(src, m)]))
      i = nextind(src, min(m, lastindex(src)))
    elseif Base.is_id_start_char(src[k])
      m = k
      while m <= lastindex(src) && Base.is_id_char(src[m])
        m = nextind(src, m)
      end
      push!(out, src[k:prevind(src, m)])
      i = m
    else
      i = k
    end
  end
  return out
end

function _leaks971(expr::AbstractString)
  expr in VALUE_NAMES971 && return true
  occursin(r"^row\[", expr) && return true
  occursin(r"\brepr\(", expr) && return true
  occursin(r"showerror", expr) && return true
  occursin(r"^e(rr)?$", expr) && return true                 # an exception's own text
  occursin(r"\be(rr)?\.msg\b", expr) && return true           # … or its message
  return false
end

# Each construction's argument text, from `InvalidValueError(`/`FilterError(` to its matching `)`.
function _refusal_sites971(path)
  text = read(path, String)
  sites = Tuple{Int, String}[]
  for m in eachmatch(r"\b(?:InvalidValueError|FilterError|QueryBuildError)\(", text)
    start = m.offset + ncodeunits(m.match)
    depth, i = 1, start
    while i <= ncodeunits(text) && depth > 0
      c = text[i]
      c == '(' && (depth += 1)
      c == ')' && (depth -= 1)
      i = nextind(text, i)
    end
    line = count(==('\n'), SubString(text, 1, m.offset)) + 1
    push!(sites, (line, String(SubString(text, start, prevind(text, i)))))
  end
  return sites, split(text, '\n')
end

@testset "#971: no refusal in src/ or ext/ interpolates a value" begin   # InvalidValueError, FilterError, QueryBuildError
  root = pkgdir(PormG)
  offenders = String[]
  nsites = 0
  for dir in ("src", "ext"), (base, _, files) in walkdir(joinpath(root, dir)), f in files
    endswith(f, ".jl") || continue
    path = joinpath(base, f)
    sites, lines = _refusal_sites971(path)
    for (line, args) in sites
      nsites += 1
      span = join(lines[line:min(line + count(==('\n'), args), length(lines))], "\n")
      occursin("refusal-value-ok:", span) && continue
      # Only the string literals: an argument like `kind` or `op = op` is not message text.
      for lit in eachmatch(r"\"(?:[^\"\\]|\\.)*\"", args), expr in _interpolations971(lit.match)
        _leaks971(expr) && push!(offenders, "$(relpath(path, root)):$(line) interpolates `$(expr)`")
      end
    end
  end
  @test nsites > 100        # the scan found the raise sites at all
  @test isempty(offenders)
  isempty(offenders) || foreach(o -> @info(o), offenders)
end

@testset "#971: the scanner flags a leak and passes a type" begin
  # Its own mutation check: each shape it exists to catch, and the shapes it must let through.
  for leak in ("\"got \$value\"", "\"got \$(value)\"", "\"got \$(repr(x))\"", "\"\$(sprint(showerror, e))\"",
               "\"failed: \$(e)\"", "\"(\$(e.msg))\"", "\"cell \$(row[col_name])\"")
    @test any(_leaks971, _interpolations971(leak))
  end
  for fine in ("\"got a \$(typeof(value))\"", "\"field `\$field`\"", "\"row \$(index)\"", "\"\$(e.reason)\"",
               "\"at most \$(length(text))\"")
    @test !any(_leaks971, _interpolations971(fine))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# 2. The data shape
# ─────────────────────────────────────────────────────────────────────────────
@testset "#971: InvalidValueError carries its reason and location as data" begin
  e = PormG.InvalidValueError("boom")                 # the #231 one-string form still works
  @test e.msg == "boom" && e.kind === :other && e.field === nothing && e.row === nothing

  r = PormG.InvalidValueError("The value is not a valid number", :format)
  @test r.msg == "The value is not a valid number" && r.reason == r.msg

  located = PormG.with_location(r; op = "bulk_insert", model = "result", field = "points", row = 3)
  @test located.kind === :format && located.field == "points" && located.row == 3
  @test located.msg == "Error in bulk_insert, row 3 for model result, field `points`: The value is not a valid number"
  @test PormG.error_message(located) == located.msg

  # A second funnel adds what it knows and keeps what the first set: located once.
  again = PormG.with_location(PormG.with_location(r; op = "insert", field = "points"); op = "bulk_insert", row = 9)
  @test again.op == "insert" && again.row == 9
  @test count("Error in", again.msg) == 1
end

# ─────────────────────────────────────────────────────────────────────────────
# 3. Every path, end to end
# ─────────────────────────────────────────────────────────────────────────────
using PormG.Models: Model, IDField, FloatField, IntegerField, DateField, JSONField, UUIDField
using PormG.QueryBuilder: bulk_insert, bulk_update
import PormG.ConnectionPool: fetch, SQLiteConnectionPool

refusal971(f) = try f(); nothing catch e e end

function no_secret971(e; field = nothing, row = nothing)
  @test e isa PormG.InvalidValueError
  e isa PormG.InvalidValueError || return
  @test !occursin(SECRET971, e.msg)
  @test !occursin(SECRET971, PormG.error_message(e))
  @test !occursin(SECRET971, e.reason)
  field === nothing || @test e.field == field
  row === nothing || @test e.row == row
end

function with_sqlite971(f)
  mktempdir() do dir
    pool = SQLiteConnectionPool(joinpath(dir, "refusal971.sqlite"); pool_size = 1)
    key = "refusal971_sqlite"
    PormG.config[key] = PormG.Configuration.Settings(connections = pool, db_def_folder = dir, change_data = true)
    try
      fetch(pool, "CREATE TABLE refusal971_result (id INTEGER PRIMARY KEY, points REAL, grid INTEGER, " *
                  "race_date TEXT, telemetry TEXT, code TEXT);")
      fetch(pool, "INSERT INTO refusal971_result (id, points, grid) VALUES (1, 25.0, 1);")
      model = Model("refusal971_result", id = IDField(), points = FloatField(null = true),
                    grid = IntegerField(null = true), race_date = DateField(null = true),
                    telemetry = JSONField(null = true), code = UUIDField(null = true))
      model.connect_key = key
      f(pool, model)
    finally
      delete!(PormG.config, key)
      PormG.ConnectionPool.close_pool!(pool)   # release the handle so mktempdir can clean up (Windows)
    end
  end
end

@testset "#971: the formatters refuse with a reason and a kind, never the value" begin
  for (call, kind) in ((() -> PormG.Models.format_number_sql(SECRET971), :format),
                       (() -> PormG.Models.format_uuid_sql(SECRET971), :format),
                       (() -> PormG.Models.format_date_sql(SECRET971), :format),
                       (() -> PormG.Models.format_yyyy_mm(SECRET971), :format),
                       (() -> PormG.Models.format_duration_sql(SECRET971), :format),
                       (() -> PormG.Models.format_json_sql("{\"k\": \"$SECRET971"), :format),
                       (() -> PormG.Models.format_json_sql(Dict("k" => "a\0$SECRET971")), :json_nul))
    e = refusal971(call)
    no_secret971(e)
    e isa PormG.InvalidValueError && @test e.kind === kind
  end
  # `sqlite_bind_value`, which the raw-params hatch runs on SQLite (#721).
  e = refusal971(() -> PormG.sqlite_bind_value(typemax(UInt64)))
  no_secret971(e)
  @test e.kind === :range
end

@testset "#971: SQLite — filter, write and bulk refusals name the field, never the value" begin
  with_sqlite971() do pool, model
    # The filter path: an `InvalidValueError` now (a `FilterError` until #971), located on the field.
    for (field, bad) in (("points", SECRET971), ("code", SECRET971), ("race_date", SECRET971),
                         ("telemetry", "{\"k\": \"$SECRET971"))
      e = refusal971(() -> model.objects.filter(field => bad).list())
      no_secret971(e; field = field)
      e isa PormG.InvalidValueError && @test e.op == "filter"
    end
    # The single-row writers.
    for (op, call) in (("insert", () -> model.objects.create("id" => 2, "points" => SECRET971)),
                       ("update", () -> model.objects.filter("id" => 1).update("grid" => SECRET971)),
                       ("insert", () -> model.objects.create("id" => 2, "telemetry" => Dict("k" => "a\0$SECRET971"))))
      e = refusal971(call)
      no_secret971(e)
      e isa PormG.InvalidValueError && @test e.op == op && e.field !== nothing
    end
    # The bulk writers: the row too. Row 2 of the frame holds the bad cell.
    e = refusal971(() -> bulk_insert(model.objects, DataFrame(id = [2, 3], points = [1.0, SECRET971])))
    no_secret971(e; field = "points", row = 2)
    e = refusal971(() -> bulk_update(model.objects, DataFrame(id = [1], code = [SECRET971])))
    no_secret971(e; field = "code", row = 1)
    e = refusal971(() -> bulk_insert(model.objects, DataFrame(id = [2, 3], telemetry = [Dict("lap" => 1), Dict("k" => "a\0$SECRET971")])))
    no_secret971(e; field = "telemetry", row = 2)
    e isa PormG.InvalidValueError && @test e.kind === :json_nul
  end
end
