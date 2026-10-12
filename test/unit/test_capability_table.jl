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
# `docs/src/backends.md` lists every feature with a cell per backend: `yes`, `no`, or `from <version>`
# for a version row (#1163). Parsed here and compared, row by row and in order, with
# `_BACKEND_FEATURES`, `_has_feature` and `_feature_since` — so a row added to one place and not the
# other fails, and so does a backend gaining a feature, or a version, its page does not show.
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
    since = PormG.Kernel._feature_since(T, Val(f))
    expected = !PormG.Kernel._has_feature(T, Val(f)) ? "no" :
               since === nothing ? "yes" : "from $(PormG._version_text(T, since))"
    @test r[2 + i] == expected
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
  # PostgreSQL has every row but SQLite's own catalog (`table_list`), so nothing it renders is refused
  # — on a server new enough for every version row (#1163).
  @test all(f -> PormG._supports(_CtPg(), f; server_version = 180000) == (f !== :table_list), first.(PormG._BACKEND_FEATURES))
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
    # The builder itself (a missing feature, a version gap, a call shape no renderer takes), and the
    # docstrings that name the type.
    "src/capabilities.jl" => 3, "src/exceptions.jl" => 2,
    # Dialect.jl, 19:
    #  - 14 generic `(::PormGAbstractType, column, value)` lookup arms: the guard against a value that
    #    is no bound placeholder (#602), whose error type `test_dialect_abstractstring.jl` pins;
    #  - support in part: a `ToChar` format, an `Extract` part, a cast to a time type (#822);
    #  - a meaning, not a feature: a `DecimalField` SQLite cannot store exactly (#648);
    #  - a `db_default` pinned to another engine (#496).
    "src/Dialect.jl" => 19,
    # A gap in PormG, not in the engine: SQLite has window frames, PormG does not render them there yet.
    "src/querybuilder/select_nodes.jl" => 1,
    # SQLite's parameter collector, reached with no connection at hand (an ArrayField value).
    "src/querybuilder/parameters.jl" => 1,
    # A plan's statements the server cannot run (#1146): one refusal listing each, with its own way out;
    # the features and versions are the table's (#1163).
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

# ─────────────────────────────────────────────────────────────────────────────
# Version rows (#1163): a feature a backend has from a server version
# A server at a version on each side of every version row: `_supports` says no below and yes at it; a
# refusal below names the version the row states and the server's own; a fallback row takes its
# fallback below and the native path at it. The version is asked of the connection (`_server_version`)
# unless the caller hands it the one it already asked. The versions are written out below, not read
# back from the table, so the loop is not its own oracle. Mutation gate: a row's `_feature_since` moved
# (even within a major version, which the page's `from 11` cannot show) fails the pinned `Dict`; the
# version-gap branch of `_capability_error` deleted turns the refusal into "no renderer takes".
# ─────────────────────────────────────────────────────────────────────────────
struct _CtPgAt <: PormG.PormGPostgres
  v::Int
end
PormG._server_version(c::_CtPgAt) = c.v
struct _CtSlAt <: PormG.PormGSQLite
  v::Int
end
PormG.backend_sqlite_version(c::_CtSlAt) = c.v

@testset "#1163: each version row answers no below its version and yes at it" begin
  rows = [(T, f, since) for (_, T) in PormG._BACKENDS for f in first.(PormG._BACKEND_FEATURES)
          for since in (PormG.Kernel._feature_since(T, Val(f)),) if since !== nothing]
  # The rows the server-version gates read, on the backend each is read on, at the version each
  # backend's own release notes give (the two floors are PormG's: #1162).
  Sl, Pg = PormG.PormGSQLite, PormG.PormGPostgres
  @test Dict((T, f) => since for (T, f, since) in rows) == Dict(
    (Sl, :window_functions) => 3_025_000, (Sl, :nulls_order) => 3_030_000, (Sl, :table_list) => 3_037_000,
    (Pg, :schema_introspection) => 90_600, (Pg, :migration_plans) => 110_000,
    (Pg, :identity_columns) => 100_000, (Pg, :declarative_partitions) => 100_000,
    (Pg, :include_columns) => 110_000, (Pg, :generated_columns) => 120_000,
    (Pg, :drop_expression) => 130_000, (Pg, :input_validity) => 160_000)
  conn(T, v) = T === PormG.PormGPostgres ? _CtPgAt(v) : _CtSlAt(v)
  below(T, since) = T === PormG.PormGPostgres ? since - 100 : since - 1_000
  for (T, f, since) in rows
    @test !PormG._supports(conn(T, below(T, since)), f)
    @test PormG._supports(conn(T, since), f)
    # The version a caller already asked wins over asking again.
    @test PormG._supports(conn(T, since), f; server_version = below(T, since)) == false
    @test PormG.Kernel._feature_at(T, f, since) && !PormG.Kernel._feature_at(T, f, below(T, since))
  end
  # The versions as messages say them.
  @test PormG._version_text(PormG.PormGPostgres, 90600) == "9.6"
  @test PormG._version_text(PormG.PormGPostgres, 130004) == "13"
  @test PormG._version_text(PormG.PormGSQLite, 3025000) == "3.25.0"
  @test PormG._version_text(PormG.PormGSQLite, 3045001) == "3.45.1"
end

@testset "#1163: a version gap is refused with the row's version and the server's" begin
  e = PormG._capability_error(_CtPgAt(120004), :drop_expression, "Removing `generated_from`")
  @test _ct_msg(e) == "Removing `generated_from` needs PostgreSQL 13 or newer, for removing a column's generation " *
                      "expression (`ALTER COLUMN … DROP EXPRESSION`); this server is 12 (server_version_num 120004)."
  # SQLite names its library, not a server.
  e = try PormG.Dialect._assert_sqlite_window_support(_CtSlAt(3024000)); nothing catch err; err end
  @test e isa PormG.BackendCapabilityError
  @test _ct_msg(e) == "A window function needs SQLite 3.25.0 or newer, for window functions (`OVER (…)`); " *
                      "the SQLite library PormG loads is 3.24.0."
  @test PormG.Dialect._assert_sqlite_window_support(_CtSlAt(3025000)) === nothing
  # At or above the version, the funnel says what it always said: the backend has the feature.
  e = PormG._capability_error(_CtPgAt(130000), :drop_expression, "X")
  @test occursin("no PostgreSQL renderer takes", _ct_msg(e))
  # A backend without the row at all is still the plain refusal, naming who has it.
  e = PormG._capability_error(_CtSlAt(3045000), :drop_expression, "X")
  @test occursin("which SQLite does not support (supported on PostgreSQL)", _ct_msg(e))
  # `_require_feature` asks the version once, and only for a version row.
  @test PormG._require_feature(_CtSlAt(3045000), :window_functions, "X") === nothing
  @test PormG._require_feature(_CtPg(), :arrays, "X") === nothing   # no version row: `_CtPg` has no version to ask
end

@testset "#1163: each fallback row takes its fallback below its version" begin
  QB = PormG.QueryBuilder
  M = PormG.Migrations
  # NULLS FIRST / LAST: emulated with an `(expr IS NULL)` key below SQLite 3.30.
  @test QB._emulates_nulls_order(_CtSlAt(3029000)) && !QB._emulates_nulls_order(_CtSlAt(3030000))
  # A catalog column is read where it exists, and its exact stand-in below (#1162).
  for (col, f) in ((:indnkeyatts, :include_columns), (:attidentity, :identity_columns),
                   (:relispartition, :declarative_partitions), (:attgenerated, :generated_columns))
    since = PormG.Kernel._feature_since(PormG.PormGPostgres, Val(f))
    @test M._pg_catalog_col(since, "x", col) == "x.$(col)"
    @test M._pg_catalog_col(since - 100, "x", col) != "x.$(col)"
  end
  # `pg_input_is_valid` from 16; below it the pre-check matches the type's input grammar.
  @test M._has_input_validity(_CtPgAt(160000), 160000) && !M._has_input_validity(_CtPgAt(150000), 150000)
  @test M._has_input_validity(_CtPgAt(150000), nothing)   # a caller that did not ask: the native function
end

# ─────────────────────────────────────────────────────────────────────────────
# Version rows (#1163): no server-version comparison outside the table
# A version gate written by hand (`backend_sqlite_version(conn) < X`, `v >= _SOME_FLOOR`,
# `v >= 150000`) is a version the table does not show and a message it does not generate. The scan reads
# every code line of `src/` and `ext/` (comments stripped) for a comparison with a `version`-named
# operand, a `*FLOOR*` constant, or an integer literal of five digits or more. It is a heuristic, not a
# proof: a comparison through a value it cannot see (`v < row[2]`, `v < LIMIT` for a constant with
# neither word in its name) passes it. The reviewed exceptions, each with its reason: a new one fails
# here — ask `_supports` / `_feature_at`, or add it with the reason it is not a row.
# ─────────────────────────────────────────────────────────────────────────────
@testset "#1163: server-version comparisons are only the table's and the reviewed ones" begin
  CMP = raw"(?:<=|>=|<(?![:=])|(?<![=\-])>(?!=))"
  OPERAND = raw"\w*version\w*(?:\([^()]*\))?"
  re = Regex("(?i)\\b$(OPERAND)\\s*$(CMP)|$(CMP)\\s*$(OPERAND)|(?-i)\\b[A-Z_]*FLOOR[A-Z_]*\\b\\s*$(CMP)|$(CMP)\\s*[A-Z_]*FLOOR[A-Z_]*\\b|" *
             "$(CMP)\\s*\\d[\\d_]{4,}\\b|\\b\\d[\\d_]{4,}\\s*$(CMP)")
  reviewed = Dict(
    # The table itself: `_feature_at`, and `_version_text`'s PostgreSQL 10 boundary (one number from 10 on).
    "src/capabilities.jl" => 2,
    # A quantity, not a yes or no: SQLite's bind-parameter limit, 999 before 3.32 and 32766 from it.
    "src/querybuilder/execution_bulk.jl" => 1,
    # PormG's own release versions (`upgrade_guide(from, to)`), not a server's.
    "src/tools.jl" => 1,
    # Not versions: a byte bound in a docstring's CHECK example, and a rounding threshold.
    "src/migrations/introspection.jl" => 1, "src/querybuilder/expression_render.jl" => 1,
  )
  found = Dict{String,Int}()
  for top in ("src", "ext"), (dir, _, files) in walkdir(joinpath(_CT_ROOT, top)), f in files
    endswith(f, ".jl") || continue
    path = joinpath(dir, f)
    n = open(path) do io
      count(l -> !startswith(lstrip(l), "#") && occursin(re, replace(l, r"#.*$" => "")), eachline(io))
    end
    n > 0 && (found[replace(relpath(path, _CT_ROOT), '\\' => '/')] = n)   # '/' on Windows too
  end
  @test found == reviewed
  # The scan sees the shapes it exists for.
  for gate in ("if version_number < SQLITE_WINDOW_MIN_VERSION",
               "_emulates_nulls_order(conn) = backend_sqlite_version(conn) < 3030000",
               "v >= _PG_INTROSPECTION_FLOOR && return v",
               "x = server_version >= 120000 ? a : b",
               "v >= 110000 && return v",
               "v = _pg_server_version(db); v < 120000")
    @test occursin(re, gate)
  end
  @test !occursin(re, "\"version\" => v") && !occursin(re, "f(x) -> version")
end
