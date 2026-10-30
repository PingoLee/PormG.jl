"""
A models-file name that cannot be its module's name is refused, by both writers (#1486).

A generated models file is `module <stem> … end`, the stem being the file name without `.jl`. The
stem was never checked, so `create_models_jl(d, "f1-models.jl")` wrote `module f1-models` and the
error came only at `include` (an `UndefVarError`: `module f1` with `-models` for a body). `1975.jl`
was a `TypeError` there and `module.jl` a `ParseError`. Both writers, `create_models_jl` and
`generate_models_from_db` (the live importers' `file` keyword), now derive the name in one helper
and raise `ModelDefinitionError` before anything is written.

No SQL and no server: both writers only write a file, and each case is checked by loading it.

julia --project=test/integration test/unit/test_models_file_name.jl
"""

using Test
using PormG

const Generator1486 = PormG.Generator

# The two writers, behind one signature: `(dir, filename) -> nothing`. `generate_models_from_db`
# takes a settings object it does not read, and an empty model list writes just the envelope.
const WRITERS1486 = [
    "create_models_jl" => (d, name) -> Generator1486.create_models_jl(d, name),
    "generate_models_from_db" => (d, name) ->
        Generator1486.generate_models_from_db(name, Any[], PormG.Configuration.Settings(); path = d),
]

# Load a written file the way `include` does, in a fresh module. Returns `nothing` on success.
function _load1486(p)
    try
        Base.include(Module(), p)
        return nothing
    catch e
        return e
    end
end

@testset "a file name that is not an identifier is refused and writes nothing: $(w) (#1486)" for (w, write!) in WRITERS1486
    # Each row of the issue's table, plus the all-underscore name `isidentifier` accepts and Julia
    # treats as a discard, and a `.jl` in the middle of a name, which the old `replace` removed
    # (`f1.jl_models.jl` became `module f1_models`) and `splitext` keeps.
    for (name, stem) in ("f1-models.jl" => "f1-models", "module.jl" => "module",
                         "1975.jl" => "1975", "_.jl" => "_", "f1.jl_models.jl" => "f1.jl_models")
        mktempdir() do d
            err = try
                write!(d, name)
                nothing
            catch e
                e
            end
            @test err isa PormG.ModelDefinitionError
            @test isempty(readdir(d))                                   # nothing written
            # The message names the file, the module it would be, and a name that works.
            @test err !== nothing && occursin("\"$(name)\"", err.msg)
            @test err !== nothing && occursin("\"$(stem)\" is not a Julia identifier", err.msg)
            @test err !== nothing && occursin("f1_models.jl", err.msg)
        end
    end
end

# An identifier can still be a name the file imports: `module Models` hides `PormG.Models`, so its
# first `Models.IDField()` is an `UndefVarError`, and `module CASCADE` hands the module itself to
# `on_delete = CASCADE`. Found in review of #1486; every reserved binding is refused, not just those two.
@testset "a file named after a binding the file imports is refused: $(w) (#1486)" for (w, write!) in WRITERS1486
    for stem in PormG.GENERATED_MODULE_RESERVED_BINDINGS
        mktempdir() do d
            err = try
                write!(d, "$(stem).jl")
                nothing
            catch e
                e
            end
            @test err isa PormG.ModelDefinitionError
            @test isempty(readdir(d))
            @test err !== nothing && occursin("\"$(stem)\" is a name the file imports from `PormG.Models`", err.msg)
        end
    end
end

@testset "an identifier file name writes a module that loads: $(w) (#1486)" for (w, write!) in WRITERS1486
    mktempdir() do d
        @test write!(d, "f1_models.jl") === nothing
        p = joinpath(d, "f1_models.jl")
        @test readline(p) == "module f1_models"
        @test _load1486(p) === nothing          # the defect was a file that could not be loaded
    end
    # A decomposed `é` (`e` + U+0301, as an older macOS filesystem lists it) is the identifier the
    # parser reads as composed `é`; it is accepted, and the module line is written composed.
    mktempdir() do d
        name = "pérez_models.jl"
        @test write!(d, name) === nothing
        p = joinpath(d, name)
        @test readline(p) == "module pérez_models"
        @test _load1486(p) === nothing
    end
end

# `create_models_jl` returns without writing when the file exists. Such a file is the user's: it can
# declare any module and load through `@import_models … as`, so its name is not judged, and a
# `setup` re-run over an existing project still accepts the name it has.
@testset "create_models_jl leaves an existing file alone, whatever its name (#1486)" begin
    mktempdir() do d
        p = joinpath(d, "f1-models.jl")
        write(p, "module F1Models\nend\n")
        @test Generator1486.create_models_jl(d, "f1-models.jl") === nothing
        @test read(p, String) == "module F1Models\nend\n"
    end
end
