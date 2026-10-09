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
     exception carries `# refusal-value-ok: <why>` on its line. The **label builders** — a function
     named `_…textless…`, `_…divergent…` or `_…_label…`, which writes a refusal's text outside its
     constructor — are held to the same rule, parsed rather than matched as text (#1057). So is
     every **local variable** a refusal prints, followed to its assignments in the same function
     (#1092: a `hint` carried a `Regex`'s pattern past the constructor scan); a reviewed assignment
     carries the marker on the assignment's first line.
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

# A label builder writes the "what" of a refusal outside its constructor — `Concat` refuses "a Float64
# literal" that `_textless_literal` named — so the scan above never sees its text. #1057 found
# `_textless_literal` printing the value that way, through `Concat`, `Cast` and `Round`. The
# convention the scan can see is the name: a function named `_…textless…`, `_…divergent…` or
# `_…_label…` builds refusal text, and every interpolation in its body is held to the same rule.
const LABEL_BUILDER971 = r"^_\w*(?:textless|divergent|_label)"

_def_name971(sig::Symbol) = sig
_def_name971(sig::Expr) = sig.head in (:call, :where, :(::)) ? _def_name971(sig.args[1]) :
  sig.head === :. && sig.args[end] isa QuoteNode ? sig.args[end].value : nothing   # `Base.setproperty!`
_def_name971(::Any) = nothing

# Every definition whose name matches, as `(name, line, definition)`: the long form and the short
# one. `line` is the definition's first line, where a reviewed exception's marker goes.
function _label_builders971(ex, found = Tuple{Symbol, Int, Expr}[], line = 0)
  ex isa Expr || return found
  if (ex.head === :function || (ex.head === :(=) && ex.args[1] isa Expr)) && length(ex.args) == 2
    name = _def_name971(ex.args[1])
    if name isa Symbol && occursin(LABEL_BUILDER971, String(name))
      push!(found, (name, line, ex))
      return found
    end
  end
  for a in ex.args
    a isa LineNumberNode ? (line = a.line) : _label_builders971(a, found, line)
  end
  return found
end

# What a body writes into text, as `_leaks971` reads it: every interpolation, and every operand of a
# `string(…)`, `repr(…)` or `*` outside one — `"the literal " * string(x)` is the same leak.
function _ast_interpolations971(ex, out = String[])
  ex isa Expr || return out
  ex.head === :string && foreach(a -> a isa String || push!(out, string(a)), ex.args)
  ex.head === :call && ex.args[1] in (:string, :repr, :*) &&
    foreach(a -> a isa String || push!(out, string(a)), ex.args[2:end])
  foreach(a -> _ast_interpolations971(a, out), ex.args)
  return out
end

# A builder's value has two more spellings than a constructor's: an `SQLText` literal keeps its value
# in `.field` (`$(p.field)` is the likeliest way back to #1057), and `string(x)` of a value name.
_label_leaks971(expr) = _leaks971(expr) || occursin(r"\.field$", expr) ||
  ((m = match(r"^string\((\w+)\)$", expr)) !== nothing && m.captures[1] in VALUE_NAMES971)

@testset "#1057: no refusal label builder interpolates a value" begin
  root = pkgdir(PormG)
  offenders = String[]
  nbuilders = 0
  for dir in ("src", "ext"), (base, _, files) in walkdir(joinpath(root, dir)), f in files
    endswith(f, ".jl") || continue
    path = joinpath(base, f)
    lines = readlines(path)
    for (name, line, def) in _label_builders971(Meta.parseall(read(path, String)))
      nbuilders += 1
      occursin("refusal-value-ok:", get(lines, line, "")) && continue
      for expr in _ast_interpolations971(def.args[2])
        _label_leaks971(expr) && push!(offenders, "$(relpath(path, root)):$(line) `$(name)` writes `$(expr)`")
      end
    end
  end
  @test nbuilders > 50      # the scan found the builders at all (#1057: 77 definitions, 42 names)
  @test isempty(offenders)
  isempty(offenders) || foreach(o -> @info(o), offenders)
end

# A local variable is the other way a value reaches a refusal without appearing inside its constructor.
# #1092 found the `@regex` refusal building `hint = "… $(repr(x.second.pattern)) …"` and printing
# `$(hint)`. So every name a refusal interpolates (or `*`-joins) is followed to its assignments in the
# same function, transitively, and each one's text is held to the label-builder rule. A reviewed
# assignment carries `# refusal-value-ok: <why>` on its first line, a refusal on its statement's.
const REFUSALS1092 = (:InvalidValueError, :FilterError, :QueryBuildError)

# Every top-level definition, long and short form, as `(line, definition)`. A closure is scanned with
# the function that holds it, so a refusal inside it sees that function's locals too.
function _definitions1092(ex, found = Tuple{Int, Expr}[], line = 0)
  ex isa Expr || return found
  if (ex.head === :function || (ex.head === :(=) && ex.args[1] isa Expr)) && length(ex.args) == 2 &&
     _def_name971(ex.args[1]) isa Symbol
    push!(found, (line, ex))
    return found
  end
  for a in ex.args
    a isa LineNumberNode ? (line = a.line) : _definitions1092(a, found, line)
  end
  return found
end

# A body's refusal constructions and its local assignments `name = rhs` / `name *= rhs`, each with its
# line. A `for` loop's `v in values` parses as `v = values`, so an element of a value collection is
# followed too.
function _refusals_and_locals1092(body)
  calls = Tuple{Int, Expr}[]
  locals = Dict{Symbol, Vector{Tuple{Int, Any}}}()
  line = Ref(0)
  function walk(ex)
    ex isa LineNumberNode && (line[] = ex.line; return)
    ex isa Expr || return
    ex.head === :call && ex.args[1] in REFUSALS1092 && push!(calls, (line[], ex))
    ex.head in (:(=), :*=) && ex.args[1] isa Symbol && push!(get!(locals, ex.args[1], Tuple{Int, Any}[]), (line[], ex.args[2]))
    foreach(walk, ex.args)
  end
  walk(body)
  return calls, locals
end

# The bare names an expression writes into text: `$name` and the operands of `string(…)` or `*`.
function _written_names1092(ex, out = Set{Symbol}())
  ex isa Symbol && return push!(out, ex)        # `msg = hint` is an alias, followed like the rest
  ex isa Expr || return out
  ex.head === :string && foreach(a -> a isa Symbol && push!(out, a), ex.args)
  ex.head === :call && ex.args[1] in (:string, :*) && foreach(a -> a isa Symbol && push!(out, a), ex.args[2:end])
  foreach(a -> a isa Symbol || _written_names1092(a, out), ex.args)
  return out
end

# Each leak in `src`, as text: the assignment that writes a value, and the refusal that prints it.
function _local_offenders1092(src::AbstractString)
  lines = split(src, '\n')
  offenders = String[]
  ncalls = 0
  for (_, def) in _definitions1092(Meta.parseall(src))
    calls, locals = _refusals_and_locals1092(def.args[2])
    for (cl, call) in calls
      ncalls += 1
      occursin("refusal-value-ok:", get(lines, cl, "")) && continue
      todo = Symbol[n for arg in call.args[2:end] for n in _written_names1092(arg)]   # `FilterError(msg)` too
      seen = Set{Symbol}()
      while !isempty(todo)
        name = pop!(todo)
        name in seen && continue
        push!(seen, name)
        for (al, rhs) in get(locals, name, ())
          occursin("refusal-value-ok:", get(lines, al, "")) && continue
          wrapped = Expr(:block, rhs)
          for expr in _ast_interpolations971(wrapped)
            _label_leaks971(expr) && push!(offenders, "$(al): `$(name)` writes `$(expr)`, printed by the refusal at $(cl)")
          end
          rhs isa Symbol && String(rhs) in VALUE_NAMES971 &&
            push!(offenders, "$(al): `$(name)` is `$(rhs)`, printed by the refusal at $(cl)")
          # A whole right-hand side `repr(…)` — the pieces above are only its operands.
          rhs isa Expr && rhs.head === :call && _leaks971(string(rhs)) &&
            push!(offenders, "$(al): `$(name)` is `$(rhs)`, printed by the refusal at $(cl)")
          append!(todo, _written_names1092(rhs))
        end
      end
    end
  end
  return unique(offenders), ncalls
end

@testset "#1092: no refusal prints a value through a local variable" begin
  root = pkgdir(PormG)
  offenders = String[]
  ncalls = 0
  for dir in ("src", "ext"), (base, _, files) in walkdir(joinpath(root, dir)), f in files
    endswith(f, ".jl") || continue
    path = joinpath(base, f)
    found, n = _local_offenders1092(read(path, String))
    ncalls += n
    append!(offenders, "$(relpath(path, root)):" .* found)
  end
  @test ncalls > 400        # the scan found the refusals at all (#1092: 506, qualified names included)
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
  # The label-builder scan, on #1057's own defect in both definition forms, the spellings it would
  # come back as, and the fix.
  for (src, leaks) in (("_textless_literal(x::Bool) = (:bool, \"the literal \$(x)\")", true),
                       ("function _textless_literal(x::AbstractFloat)\n  (:float, \"the \$(typeof(x)) literal \$(x)\")\nend", true),
                       ("_textless_literal(p) = (:float, \"the literal \$(p.field)\")", true),
                       ("_textless_literal(x) = (:float, \"the literal \$(string(x))\")", true),
                       ("_textless_literal(x) = (:float, \"the literal \" * string(x))", true),
                       ("_textless_literal(x) = (:float, \"the literal \" * repr(x))", true),
                       ("_textless_literal(x::AbstractFloat) = (:float, \"a \$(typeof(x)) literal\")", false),
                       ("_unrelated(x) = \"the literal \$(x)\"", false))   # not a builder by name
    found = _label_builders971(Meta.parseall(src))
    @test any(any(_label_leaks971, _ast_interpolations971(d.args[2])) for (_, _, d) in found) == leaks
  end
  # The local-variable scan, on #1092's own defect, the likeliest spellings it would come back as,
  # and the shapes it must let through.
  for (src, leaks) in ((raw"""
                        function f(x)
                          hint = "e.g. surname__@regex => $(repr(x.second.pattern))"
                          throw(FilterError("a Julia Regex is not a filter value. $(hint)"))
                        end""", true),
                       (raw"""
                        function f(value)
                          detail = "got $(value)"
                          hint = "see " * detail
                          throw(QueryBuildError("bad input; $(hint)"))
                        end""", true),
                       (raw"""
                        function f(value)
                          msg = value
                          throw(InvalidValueError("bad input: $msg", :format))
                        end""", true),
                       (raw"""f(v) = (shown = repr(v); throw(InvalidValueError("bad $(shown)")))""", true),
                       (raw"""
                        function f(values)
                          for item in values
                            item isa String || throw(QueryBuildError("bad argument: $(item)"))
                          end
                        end""", true),    # `.values(…)`'s refusal, until #1092's scan saw it
                       (raw"""
                        function f(value)
                          msg = "bad input: $(value)"
                          throw(FilterError(msg))
                        end""", true),    # the message itself is the local
                       (raw"""
                        function f(value)
                          msg = "bad input"
                          msg *= ": $(value)"
                          throw(FilterError(msg))
                        end""", true),
                       (raw"""
                        function f(x)
                          pat = repr(x.second.pattern)
                          throw(FilterError("pass it as a String, e.g. $(pat)"))
                        end""", true),    # #1092 re-spelled in two steps
                       (raw"""
                        function Base.setproperty!(row, sym::Symbol, value)
                          hint = "got $(value)"
                          throw(InvalidValueError("bad $(hint)"))
                        end""", true),    # a qualified name is a definition too
                       (raw"""
                        function f(value)
                          hint = "got a $(typeof(value))"
                          throw(FilterError("bad input; $(hint)"))
                        end""", false),
                       (raw"""
                        function f(s)
                          shown = repr(s)  # refusal-value-ok: SQL grammar
                          throw(InvalidValueError("bad $(shown)"))
                        end""", false),
                       (raw"""
                        function f(value)
                          hint = "got $(value)"
                          @info hint
                          throw(FilterError("bad input"))
                        end""", false))    # the value is logged, not refused: not this scan's business
    @test !isempty(first(_local_offenders1092(src))) == leaks
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

@testset "#1092: a Regex refusal names the lookup, never the pattern" begin
  with_sqlite971() do pool, model
    # The pattern is the value: a search box can supply it. A caseless one still steers to the twin.
    for (pattern, twin) in ((Regex(SECRET971), "code__@regex"), (Regex(SECRET971, "i"), "code__@iregex"))
      e = refusal971(() -> model.objects.filter("code__@regex" => pattern).list())
      @test e isa PormG.FilterError
      e isa PormG.FilterError || continue
      @test !occursin(SECRET971, e.msg)
      @test !occursin(SECRET971, PormG.error_message(e))
      @test occursin("\"$(twin)\" => \"<pattern>\"", PormG.error_message(e))
    end
  end
end

@testset "#1092: an invalid values() argument is named by its type, never printed" begin
  with_sqlite971() do pool, model
    e = refusal971(() -> model.objects.values(Dict(SECRET971 => 1)).list())
    @test e isa PormG.QueryBuildError
    e isa PormG.QueryBuildError || return
    @test !occursin(SECRET971, PormG.error_message(e))
    @test occursin("Invalid argument: a Dict{String, Int64}", PormG.error_message(e))
  end
end
