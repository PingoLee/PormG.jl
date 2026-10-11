# ==============================================================================
# The backend capability table (#1129)
#
# Which optional features each backend has (`src/capabilities.jl`), and the one refusal for a feature
# a backend lacks. Before the table each refusal was written by hand at its own site, against one
# engine pair ("requires PostgreSQL", "Use bulk_insert for SQLite"), and dispatched on `PormGSQLite`:
# a third backend reached an `InvalidValueError`, a `MethodError`, or no refusal at all. This file pins
# the table against its documentation, the call sites against the table, the refusal's wording, and
# the list of capability errors still built by hand, each with its reason.
#
# Run: julia --project=test/integration test/unit/test_capability_table.jl
# ==============================================================================

using Test
using PormG

const _CT_ROOT = pkgdir(PormG)
struct _CtPg <: PormG.PormGPostgres end
struct _CtSl <: PormG.PormGSQLite end
struct _CtOther <: PormG.PormGBackend end   # a backend with no rows yet, as a new one starts (#1130)
_ct_msg(e) = replace(sprint(showerror, e), r"\e\[[0-9;]*m" => "")

# ─────────────────────────────────────────────────────────────────────────────
# Capability table: the documented table is the code's table
# `docs/src/backends.md` lists every feature with a yes/no per backend. Parsed here and compared,
# row by row and in order, with `_BACKEND_FEATURES` and `_has_feature` — so a row added to one place
# and not the other fails, and so does a backend gaining a feature its page does not show.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1129: docs/src/backends.md lists exactly the capability table" begin
  text = read(joinpath(_CT_ROOT, "docs", "src", "backends.md"), String)
  lines = [l for l in split(text, '\n') if startswith(l, "| `")]
  rows = [strip.(split(strip(l, '|'), '|')) for l in lines]
  header = strip.(split(strip(only(l for l in split(text, '\n') if startswith(l, "| Feature")), '|'), '|'))
  backends = header[3:end]
  @test backends == [first(b) for b in PormG._BACKENDS]
  @test [Symbol(strip(r[1], '`')) for r in rows] == [first(f) for f in PormG._BACKEND_FEATURES]
  for r in rows, (i, name) in enumerate(backends)
    f = Symbol(strip(r[1], '`'))
    T = last(PormG._BACKENDS[findfirst(b -> first(b) == name, PormG._BACKENDS)])
    @test (r[2 + i] == "yes") == PormG.Kernel._has_feature(T, Val(f))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Capability table: every feature a call site names is a row
# A refusal or a check that names a feature the table does not have would throw `InvalidValueError`
# only when reached. The scan catches a symbol written as the feature argument of `_supports`,
# `_capability_error` or `_require_feature`; the specialized field types name theirs through
# `Dialect._field_feature`, asked directly below, as is the reason table keyed by them.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1129: every feature src/ names is a row of the table" begin
  names = Set(first.(PormG._BACKEND_FEATURES))
  used = Set{Symbol}()
  for (dir, _, files) in walkdir(joinpath(_CT_ROOT, "src")), f in files
    endswith(f, ".jl") || continue
    for m in eachmatch(r"(?:_supports|_capability_error|_require_feature)\([^,()]*(?:\([^()]*\))?[^,()]*,\s*:(\w+)", read(joinpath(dir, f), String))
      push!(used, Symbol(m.captures[1]))
    end
  end
  @test !isempty(used)
  @test setdiff(used, names) == Set{Symbol}()
  M = PormG.Models
  for field in (M.ArrayField(M.IntegerField()), M.SearchVectorField(), M.GenericIPAddressField(), M.CIDRField())
    @test PormG.Dialect._field_feature(field) in names
  end
  @test Set(keys(PormG.Dialect._UNSUPPORTED_TYPE_WHY)) ⊆ names
  @test_throws PormG.InvalidValueError PormG._supports(_CtPg(), :no_such_feature)
end

# ─────────────────────────────────────────────────────────────────────────────
# Capability table: the refusal names the feature, the backend at hand and who has it
# Never a pair of engines: the backends offered come from the table, so the sentence stays true when
# a backend is added. A backend with no rows (a third one, as #1130 will add) refuses through the
# same lookups that used to reach `InvalidValueError` ("The value must be a String") or a
# `MethodError` for want of a SQLite method.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1129: the refusal names the feature and the backend at hand" begin
  D = PormG.Dialect
  e = try D.jcontains(_CtSl(), "c", "?"); nothing catch err; err end
  @test e isa PormG.BackendCapabilityError
  @test _ct_msg(e) == "The @jcontains lookup (JSONB @>) needs JSONB containment and key operators " *
                      "(`@>`, `?`, `?|`, `?&`), which SQLite does not support (supported on PostgreSQL)."
  # A third backend: every table-backed lookup refuses with the capability error, naming it.
  for (f, args) in ((D.jcontains, ("c", "?")), (D.acontains, ("c", "?")), (D.net_contains, ("c", "?")),
                    (D.regex, ("c", "?")), (D.iunaccent_exact, ("c", "?")), (D.niunaccent_contains, ("c", "?")),
                    (D.search, ("v", "q")))
    err = try f(_CtOther(), args...); nothing catch x; x end
    @test err isa PormG.BackendCapabilityError
    @test occursin("which _CtOther does not support (supported on PostgreSQL)", _ct_msg(err))
  end
  # Reached on a backend that HAS the feature (a call shape no renderer takes), the error never says
  # the backend lacks it.
  e_pg = PormG._capability_error(_CtPg(), :arrays, "An ArrayField index")
  @test !occursin("does not support", _ct_msg(e_pg)) && occursin("no PostgreSQL renderer takes", _ct_msg(e_pg))
  # PostgreSQL has every row, so nothing it renders is refused.
  @test all(f -> PormG._supports(_CtPg(), f), first.(PormG._BACKEND_FEATURES))
  @test !any(f -> PormG._supports(_CtOther(), f), first.(PormG._BACKEND_FEATURES))
  # A declaration a backend lacks is refused for any backend, not SQLite by name.
  arr = PormG.Models.ArrayField(PormG.Models.IntegerField())
  err = try D._refuse_unsupported_type(_CtOther(), "laps", arr); nothing catch x; x end
  @test err isa PormG.BackendCapabilityError && occursin("ArrayField \"laps\"", _ct_msg(err))
  @test D._refuse_unsupported_type(_CtPg(), "laps", arr) === nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# Capability table: a capability error is built through the table, or listed here with its reason
# A `BackendCapabilityError(` written by hand bypasses the table, and with it the wording rule. Each
# file's count below is the reviewed list; a new one fails here: raise it through `_capability_error`,
# or add it with the reason it is not a table row.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1129: hand-built capability errors are only the reviewed ones" begin
  reviewed = Dict(
    # The builder itself, and the docstrings that name the type.
    "src/capabilities.jl" => 2, "src/exceptions.jl" => 2,
    # Dialect.jl, 20:
    #  - 14 generic `(::PormGAbstractType, column, value)` lookup arms: the guard against a value that
    #    is no bound placeholder (#602), whose error type `test_dialect_abstractstring.jl` pins;
    #  - support in part: a `ToChar` format, an `Extract` part, a cast to a time type (#822);
    #  - a server version: window functions on SQLite < 3.25;
    #  - a meaning, not a feature: a `DecimalField` SQLite cannot store exactly (#648);
    #  - a `db_default` pinned to another engine (#496).
    "src/Dialect.jl" => 20,
    # A gap in PormG, not in the engine: SQLite has window frames, PormG does not render them there yet.
    "src/querybuilder/select_nodes.jl" => 1,
    # SQLite's parameter collector, reached with no connection at hand (an ArrayField value).
    "src/querybuilder/parameters.jl" => 1,
    # A server version: schema management on PostgreSQL < 13 (#1108).
    "src/migrations/introspection.jl" => 1,
    # `import_models_from_sqlite` pointed at a backend that is not the one it reads.
    "src/migrations/importers.jl" => 1,
  )
  found = Dict{String,Int}()
  for (dir, _, files) in walkdir(joinpath(_CT_ROOT, "src")), f in files
    endswith(f, ".jl") || continue
    path = joinpath(dir, f)
    n = count(l -> occursin("BackendCapabilityError(", l) && !startswith(lstrip(l), "#"), eachline(path))
    n > 0 && (found[replace(relpath(path, _CT_ROOT), '\\' => '/')] = n)   # '/' on Windows too
  end
  @test found == reviewed
end
