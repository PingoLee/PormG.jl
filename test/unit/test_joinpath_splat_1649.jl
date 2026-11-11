"""
Source pin: no `joinpath(…, x...)` in `src/` (#1649).

What it pins: no call to `joinpath` (bare, `Base.joinpath` or `Base.Filesystem.joinpath`) anywhere in
`src/` has a last argument spliced with `...`. A collection of path parts goes to
`joinpath(parts)`, Base's `joinpath(::Union{Tuple, AbstractVector})`, which returns the same value.

Why it matters: a splat of a `Vector` lowers to `Core._apply_iterate(iterate, joinpath, parts)`, a
call whose argument count is only known at run time. The JIT does not care, but a `juliac --trim`
image cannot make it: the #1600 spike's trimmed binary raised `MethodError` at the first statement of
`Configuration.load`, `_canonical_folder_path`'s `joinpath(parts...)`, and `_binding_root` had the
same shape (#1599). The scan reads the parsed source rather than grepping the text, so a call split
over lines is caught and a splat inside a comment or a string literal is not.

No SQL, no database.
"""
# julia --project=test/integration test/unit/test_joinpath_splat_1649.jl

using Test
using PormG
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))

# Suffixed names: `runtests.jl` includes every unit file into one module.
_is_joinpath_callee_1649(f) = f === :joinpath ||
  (f isa Expr && f.head === :. && last(f.args) isa QuoteNode && last(f.args).value === :joinpath)

_is_joinpath_splat_1649(ex) = ex isa Expr && ex.head === :call && length(ex.args) >= 2 &&
  _is_joinpath_callee_1649(ex.args[1]) && last(ex.args) isa Expr && last(ex.args).head === :...

# Every offending call in `ex`, as the line of the statement that holds it.
function _joinpath_splats_1649(ex, found = Int[], line = Ref(0))
  if ex isa LineNumberNode
    line[] = ex.line
  elseif ex isa Expr
    _is_joinpath_splat_1649(ex) && push!(found, line[])
    foreach(a -> _joinpath_splats_1649(a, found, line), ex.args)
  end
  return found
end

_parse_errors_1649(ex) = ex isa Expr &&
  (ex.head in (:error, :incomplete) || any(_parse_errors_1649, ex.args))

@testset "joinpath splat source pin (#1649)" begin
  @testset "the scan recognises the shape" begin
    for (src, flagged) in (
        ("joinpath(parts...)", 1),
        ("joinpath(a, b...)", 1),
        ("Base.joinpath(x...)", 1),
        ("Base.Filesystem.joinpath(x...)", 1),
        ("f(x) = \"\$(joinpath(x...))\"", 1),          # an interpolation is code
        ("joinpath(\n  root,\n  parts...,\n)", 1),       # split over lines
        ("joinpath(parts)", 0),
        ("joinpath(a, b)", 0),
        ("joinpath(folder_parts[1:end-n])", 0),
        ("f(xs...)", 0),
        ("joinpath(a...; b)", 1),                         # keyword args do not hide the splat
        ("\"joinpath(x...)\"", 0),                        # string literal
        ("# joinpath(x...)\nnothing", 0),                 # comment
      )
      @test length(_joinpath_splats_1649(Meta.parseall(src))) == flagged
    end
  end

  @testset "no joinpath splat in src/" begin
    root = normpath(joinpath(pkgdir(PormG), "src"))
    files = String[]
    for (dir, _, names) in walkdir(root), name in names
      endswith(name, ".jl") && push!(files, joinpath(dir, name))
    end
    rels = Set(relpath(f, root) for f in files)
    @test "Kernel.jl" in rels && "Models.jl" in rels       # the scan found the tree at all
    offenders = String[]
    for file in files
      ast = Meta.parseall(read(file, String); filename = file)
      @test !_parse_errors_1649(ast)
      for line in _joinpath_splats_1649(ast)
        push!(offenders, "src/$(relpath(file, root)):$(line)")
      end
    end
    @test isempty(offenders)
    isempty(offenders) || foreach(o -> @info("joinpath splat — pass the collection, joinpath(parts): $(o)"), offenders)
  end
end
