# ==============================================================================
# What PormG swallows, and only that (#1668, part of #1599)
#
# Under `juliac --trim=unsafe-warn`, a call with no compiled target raises a catchable
# `MethodError`; the process goes on. A catch-all `try` turns that into a silent wrong answer: in
# #1600's trimmed binary, `_peek_default_env` and `_peek_driver` returned `nothing` (so `load`
# skipped the #1232 driver-extension check without a word), and `_register_models!` reported success
# without recording its binding. Under the JIT the same catch-alls hid a real bug, or a Ctrl-C.
#
# This file pins three narrowed sites and one guard:
#   1. the peeks catch only what a pre-check expects (a missing or unreadable file, a YAML syntax
#      error) and answer `nothing`; anything else propagates;
#   2. `_register_models!` swallows only `Core.eval`'s own refusals (`ErrorException`);
#   3. every remaining bare `catch` in src/ says what it swallows and why, in a `# swallows …`
#      comment, or the guard fails.
#
# No SQL anywhere: no database, a mock backend, temporary files.
#
# Run: julia --project=test/integration test/unit/test_swallowed_errors.jl
# ==============================================================================

using Test
using PormG
using PormG: Configuration, Models
using YAML

# A loader that misses the way a trimmed build's call does.
_swe_missing_method(io) = throw(MethodError(_swe_missing_method, (io, :no_compiled_target)))
# A loader that fails the way an invalid connection.yml does, with YAML.jl's own error.
_swe_yaml_syntax(io) = YAML.load("dev:\n  adapter: [SQLite\n")

function _swe_with_yml(f, text::String)
  mktempdir() do dir
    file = joinpath(dir, "connection.yml")
    write(file, text)
    f(file)
  end
end

const _SWE_VALID_YML = "default_env: dev\ndev:\n  adapter: SQLite\n  database: f1.sqlite\n"
const _SWE_BROKEN_YML = "default_env: dev\ndev:\n  adapter: SQLite\n bad: [unclosed\n"

# A registered key for `set_models`, on a mock backend: registration renders no SQL.
struct SweMockPostgres <: PormG.PormGPostgres end
PormG.config["swe_mock"] = Configuration.Settings(
  connections = SweMockPostgres(), change_data = true, db_def_folder = "swe_mock")

# Every `.jl` file under src/, as path-from-package-root => lines.
function _swe_src_files()
  root = pkgdir(PormG)
  out = Pair{String, Vector{String}}[]
  for (dir, _, files) in walkdir(joinpath(root, "src")), f in files
    endswith(f, ".jl") || continue
    path = joinpath(dir, f)
    push!(out, replace(relpath(path, root), '\\' => '/') => readlines(path))
  end
  return sort!(out)
end

const _SWE_BARE_CATCH = r"\bcatch\s*(;|$)"
const _SWE_MARKER = r"#\s*swallows\b"

# The bare-catch sites ("file:line") and those with no `# swallows` comment on the line, the one
# before or the one after. A line's code part is what precedes its first `#`.
function _swe_scan(files)
  sites, missing_comment = String[], String[]
  for (key, lines) in files, (i, line) in enumerate(lines)
    startswith(lstrip(line), "#") && continue
    code = rstrip(first(split(line, '#'; limit = 2)))
    occursin(_SWE_BARE_CATCH, code) || continue
    site = "$(key):$(i)"
    push!(sites, site)
    explained = any(j -> 1 <= j <= length(lines) && occursin(_SWE_MARKER, lines[j]), (i - 1, i, i + 1))
    explained || push!(missing_comment, site)
  end
  return sites, missing_comment
end

@testset "Swallowed errors (#1668)" begin

  # What: the two pre-check reads of connection.yml, with a loader that throws a `MethodError`.
  # Expected: the `MethodError` propagates from `_peek_default_env`, `_peek_driver` and the shared
  #   `_peek_yaml`; none answers `nothing`.
  # Why: `nothing` from `_peek_driver` is how `load` skips `_require_driver_extension` (#1232), so a
  #   swallowed miss passed a load the driver check should have looked at. On main the catch-all
  #   returned `nothing` here.
  @testset "a MethodError from the YAML read propagates (the driver check is not skipped)" begin
    _swe_with_yml(_SWE_VALID_YML) do file
      @test_throws MethodError Configuration._peek_yaml(file, _swe_missing_method)
      @test_throws MethodError Configuration._peek_default_env(file, _swe_missing_method)
      @test_throws MethodError Configuration._peek_driver(file, "dev", _swe_missing_method)
      # `load` reaches the check as `_require_driver_extension(_peek_driver(…), path)`, with no
      # `try`: an answer of `nothing` is the only way the check is skipped.
      @test Configuration._require_driver_extension(nothing, "db") === nothing
    end
  end

  # What: the same reads, with a loader that throws YAML.jl's syntax error.
  # Expected: `nothing`, as before #1668.
  # Why: a syntax error is what a pre-check expects; `read_db_connection_data` parses the file right
  #   after and raises it with its own message.
  @testset "a YAML syntax error from the loader still answers nothing" begin
    _swe_with_yml(_SWE_VALID_YML) do file
      @test Configuration._peek_yaml(file, _swe_yaml_syntax) === nothing
      @test Configuration._peek_default_env(file, _swe_yaml_syntax) === nothing
      @test Configuration._peek_driver(file, "dev", _swe_yaml_syntax) === nothing
    end
  end

  # What: a real connection.yml that is not valid YAML, read by the real parser.
  # Expected: YAML.jl raises an error `_peek_yaml_expected` accepts, and both peeks answer `nothing`.
  # Why: checks the expected set against what the parser actually raises, not against a stub.
  @testset "a corrupt connection.yml still answers nothing (real parser)" begin
    _swe_with_yml(_SWE_BROKEN_YML) do file
      err = try
        YAML.load_file(file); nothing
      catch e
        e
      end
      @test err !== nothing
      @test Configuration._peek_yaml_expected(err)
      @test Configuration._peek_default_env(file) === nothing
      @test Configuration._peek_driver(file, "dev") === nothing
    end
    # And a valid file still reads (the default loader is wired).
    _swe_with_yml(_SWE_VALID_YML) do file
      @test Configuration._peek_default_env(file) == "dev"
      @test Configuration._peek_driver(file, "dev") === :sqlite
    end
  end

  # What: a missing file.
  # Expected: `nothing` (`SystemError`, expected).
  # Why: `load` refuses a missing file before the peeks run, but the peeks keep their contract.
  @testset "a missing file answers nothing" begin
    missing_file = joinpath(mktempdir(), "connection.yml")
    @test Configuration._peek_default_env(missing_file) === nothing
    @test Configuration._peek_driver(missing_file, "dev") === nothing
  end

  # ── _register_models! ───────────────────────────────────────────────────────
  # The constants it writes into the user module (`__pormg_init_path__`, `__pormg_binding__`) are a
  # restored image's fallback. Registration reads `__pormg_init_path__ != ""` inside the same `try`
  # as the `Core.eval`s, which is where these stubs throw.

  # What: a module whose `__pormg_init_path__` compares to "" with a `MethodError`.
  # Expected: `set_models` raises the `MethodError`.
  # Why: on main the catch-all swallowed it and registration reported success.
  @testset "a MethodError inside the module write propagates" begin
    mod = Module(:SweMethodErrorModels)
    Core.eval(mod, quote
      import PormG; import PormG.Models
      struct Odd end
      Base.:(==)(::Odd, ::AbstractString) = throw(MethodError(==, (Odd(), "")))
      const __pormg_init_path__ = Odd()
      Circuit::Models.ModelType = Models.Model("swe_circuit", circuitid = Models.IDField(), name = Models.CharField())
      $(PormG.Models._model_set_declaration([:Circuit]))   # #1602: the model set
    end)
    @test_throws MethodError Base.invokelatest(Models.set_models, mod, "swe_mock")
  end

  # What: a module that already declared `__pormg_init_path__` a typed global, with no value.
  # Expected: `Core.eval` refuses the `const` with an `ErrorException`, `set_models` completes,
  #   the model is bound, and no constant is written.
  # Why: that refusal is one `Core.eval` legitimately raises; today's behaviour is kept.
  @testset "Core.eval's own refusal (ErrorException) is still swallowed" begin
    mod = Module(:SweErrorExceptionModels)
    Core.eval(mod, quote
      import PormG; import PormG.Models
      global __pormg_init_path__::Int
      Circuit::Models.ModelType = Models.Model("swe_circuit2", circuitid = Models.IDField(), name = Models.CharField())
      $(PormG.Models._model_set_declaration([:Circuit]))   # #1602: the model set
    end)
    @test Base.invokelatest(Models.set_models, mod, "swe_mock") === nothing
    @test !isdefined(mod, :__pormg_init_path__)
    @test !isdefined(mod, :__pormg_binding__)
    @test Models.connection_key(Base.invokelatest(getfield, mod, :Circuit)) == "swe_mock"
  end

  # ── The guard ───────────────────────────────────────────────────────────────

  # What: every bare `catch` in src/: the grep `catch$|catch;` applied to the code part of a line
  #   (a trailing comment stripped, so the comment that answers the guard cannot hide the site).
  #   Whole-line comments are prose and skipped; a docstring's code block counts.
  # Expected: each site has a `# swallows <what>: <why>` comment on its own line, the line before
  #   or the line after.
  # Why: a silent catch-all is how a trimmed build's `MethodError` disappeared (#1600). A site that
  #   swallows on purpose says so, and a new one is reviewed when it is written.
  @testset "every bare catch in src/ says what it swallows" begin
    sites, missing_comment = _swe_scan(_swe_src_files())
    @test length(sites) >= 40     # the scan found the sites; a broken pattern finds none
    @test isempty(missing_comment)
    isempty(missing_comment) ||
      @info "bare `catch` with no `# swallows …` comment (say what it swallows and why)" missing_comment
  end

  # What: the guard's scan on synthetic lines.
  # Expected: an unexplained bare catch is flagged; an explained one, `catch e` and prose are not.
  # Why: a scan that flags nothing would pass the guard above for the wrong reason.
  @testset "the guard's scan flags an unexplained bare catch" begin
    text = ["try", "  f()", "catch", "end",                                   # 3: flagged
            "x = try g() catch; nothing end",                                 # 5: flagged
            "try", "  f()", "catch", "  # swallows X: why", "end",            # 8: explained after
            "# swallows Y: why", "y = try g() catch; nothing end",            # 12: explained before
            "z = try g() catch; 0 end  # swallows Z: why",                    # 13: explained inline
            "try", "  f()", "catch e", "  rethrow()", "end",                  # `catch e`: not a site
            "# prose that ends with catch"]                                   # comment: not a site
    sites, missing_comment = _swe_scan(["synthetic.jl" => text])
    @test sites == ["synthetic.jl:3", "synthetic.jl:5", "synthetic.jl:8", "synthetic.jl:12", "synthetic.jl:13"]
    @test missing_comment == ["synthetic.jl:3", "synthetic.jl:5"]
  end
end
