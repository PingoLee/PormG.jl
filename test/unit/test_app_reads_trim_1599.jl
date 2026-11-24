# ============================================================
# test/unit/test_app_reads_trim_1599.jl
#
# CONTRACT being tested:
#   The paths retyped so a trimmed binary runs the read shapes applications use most (#1599 layer 5) answer what the
#   code they replace answered:
#     - `Q`/`Qor` collect their terms by a recursion over the arguments (`_q_terms_of`) in place of a comprehension:
#       the same terms in the same order, the same rendered SQL and parameters, and the same first refusal for an
#       invalid argument, wherever it sits;
#     - `_check_tochar_date_of_time` reads the format through `_tochar_format` in place of an `AbstractString`
#       narrowing: the same answer for every value a node's `format` can hold, and the same refusal over a time;
#     - the regex and unaccent renderers refuse through `Dialect._capability_error_at` in place of a direct
#       `_capability_error` call: the same error type and text on every engine without the feature, and the same SQL
#       on PostgreSQL.
#   The old expressions are written out here as the oracle.
#
# Hermetic: mock connections, no database.
#
# Run: julia --project=test/integration test/unit/test_app_reads_trim_1599.jl
# ============================================================

using Test
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using PormG
using PormG: Q, Qor
using PormG.Functions: ToChar

const _AR_QB = PormG.QueryBuilder
const _AR_D = PormG.Dialect

struct ArMockSQLite <: PormG.PormGSQLite end
struct ArMockPostgres <: PormG.PormGPostgres end
struct ArMockMySQL <: PormG.PormGMySQL end
PormG.backend_sqlite_version(::ArMockSQLite) = 3045000
PormG.config["ar_mock"] = PormG.Configuration.Settings(connections = ArMockSQLite(), change_data = true,
                                                       db_def_folder = "ar_mock")

module ArModels
import PormG
import PormG.Models
Ar_circuit::Models.ModelType = Models.Model("ar_circuit",
  circuitid = Models.IDField(),
  name      = Models.CharField(max_length = 80),
)
Ar_race::Models.ModelType = Models.Model("ar_race",
  raceid    = Models.IDField(),
  year      = Models.IntegerField(),
  round     = Models.IntegerField(),
  circuitid = Models.ForeignKey("Ar_circuit", pk_field = "circuitid"),
  name      = Models.CharField(max_length = 80),
  date      = Models.DateField(),
  start     = Models.TimeField(null = true),
)
Models.@models Ar_circuit Ar_race
PormG.Models.set_models(@__MODULE__, "ar_mock")
end
const _AR_RACE = ArModels.Ar_race
const _AR_ENGINES = (ArMockSQLite(), ArMockPostgres(), ArMockMySQL())

# Run `f`, and name what it raised, so an oracle and its replacement are compared on refusals as well as values.
_ar_outcome(f) = try
  (:value, f())
catch e
  (:raised, typeof(e), sprint(showerror, e))
end

# The comprehension `Q` and `Qor` used before (#863), the oracle for `_q_terms_of`.
_ar_old_terms(x...) = [isa(v, Pair) ? _AR_QB._check_filter(v) : isa(v, _AR_QB.FilterType) ? _AR_QB._check_filter_node(v) :
                       throw(PormG.FilterError("Invalid argument: a $(typeof(v)); please use a pair (key => value).")) for v in x]

# A query's rendered SQL and parameters on `conn`, or what the render raised.
_ar_render(q, conn) = _ar_outcome(() -> _AR_QB.query(q; connection = conn, show_query = :dict))

@testset "the app's read shapes answer as before under their trimmed paths (#1599 layer 5)" begin

  # What: `Q`/`Qor` over mixed arguments, against the comprehension they used.
  # Expected: the same terms (type and rendered SQL), in the same order, on every engine; the same refusal, from the
  #   same argument, when one is invalid.
  # Why: `_q_terms_of` replaced the comprehension so a trimmed image has code for it; a different order or refusal
  #   would change the SQL or the error a caller sees.
  @testset "Q and Qor collect the same terms as the comprehension did" begin
    arg_sets = (("round__@lt" => 3, Q("name__@icontains" => "monaco", "year" => 2008)),
                ("year" => 2008, "round__@gte" => 6),
                (Q("year" => 2008), Qor("round" => 6, "round" => 18), "name__@contains" => "Grand"),
                ())
    for args in arg_sets
      new_terms = _AR_QB._q_terms_of(args)
      old_terms = _ar_old_terms(args...)
      @test map(typeof, new_terms) == map(typeof, old_terms)
      for conn in _AR_ENGINES
        for (mk, wrap) in ((Q, _AR_QB.QObject), (Qor, _AR_QB.QorObject))
          isempty(args) && continue
          new_q = _AR_RACE.objects.filter(mk(args...)).values("name")
          old_node = wrap === _AR_QB.QObject ? _AR_QB.QObject(filters = old_terms) : _AR_QB.QorObject(or = old_terms)
          old_q = _AR_RACE.objects.filter(old_node).values("name")
          @test (nameof(typeof(conn)), nameof(mk), _ar_render(new_q, conn)) == (nameof(typeof(conn)), nameof(mk), _ar_render(old_q, conn))
        end
      end
    end
    @test _AR_QB.Q().filters == _AR_QB.QObject(filters = _ar_old_terms()).filters
    # From 32 arguments on, the loop arm (`Base.Any32`): the same terms, the same SQL, and the same first refusal.
    many = Tuple(("round" => i) for i in 1:40)
    @test map(typeof, _AR_QB._q_terms_of(many)) == map(typeof, _ar_old_terms(many...))
    for conn in _AR_ENGINES
      @test _ar_render(_AR_RACE.objects.filter(Qor(many...)).values("name"), conn) ==
            _ar_render(_AR_RACE.objects.filter(_AR_QB.QorObject(or = _ar_old_terms(many...))).values("name"), conn)
    end
    bad = (many..., :k => 1, 5)
    @test _ar_outcome(() -> _AR_QB._q_terms_of(bad)) == _ar_outcome(() -> _ar_old_terms(bad...))
    # An invalid argument raises the same refusal from the same position: a value that is no pair, before and after an
    # unknown field.
    # Two arguments that raise different refusals, in both orders (a non-String key raises its own `FilterError`
    # when the term is checked), so the first one in argument order is the one raised.
    for args in ((5, "nosuchfield" => 1), ("nosuchfield" => 1, 5), ("year" => 2008, :x), (:k => 1, 5), (5, :k => 1))
      @test (args, _ar_outcome(() -> _AR_QB._q_terms_of(args))) == (args, _ar_outcome(() -> _ar_old_terms(args...)))
      @test (args, _ar_outcome(() -> Qor(args...))) == (args, _ar_outcome(() -> _AR_QB.QorObject(or = _ar_old_terms(args...))))
    end
  end

  # What: `ToChar`'s date-of-time check, reading the format through `_tochar_format`, against the `AbstractString`
  #   narrowing it replaced, for every value a node's `format` can hold; and the refusal over a time on every engine.
  # Expected: the same answer for each value, and the same refusal text.
  # Why: the check decides whether a `ToChar` over a time is refused; a different answer would let one through or refuse
  #   a valid one.
  @testset "ToChar's format check answers as the AbstractString narrowing did" begin
    old_reads(v) = (format = get(v.kwargs, "format", nothing); format isa AbstractString && _AR_D._tochar_reads_date(format))
    new_reads(v) = (format = _AR_QB._tochar_format(v); format !== nothing && _AR_D._tochar_reads_date(format))
    for fmt in ("YYYY-MM", "HH24:MI", "YYYY", SubString("YYYY-MM-DD", 1, 7), SubString("xxHH24", 3), nothing, 5)
      node = ToChar("date", "YYYY")
      fmt === nothing ? delete!(node.kwargs, "format") : (node.kwargs["format"] = fmt)
      @test (fmt, new_reads(node)) == (fmt, old_reads(node))
    end
    for conn in _AR_ENGINES
      q = _AR_RACE.objects.values("name", "d" => ToChar("start", "YYYY-MM-DD"))
      r = _ar_render(q, conn)
      @test r[1] === :raised && r[2] === PormG.QueryBuildError && occursin("over a time is not supported", r[3])
      q2 = _AR_RACE.objects.values("name", "ym" => ToChar("date", "YYYY-MM")).order_by("-ym")
      @test _ar_render(q2, conn)[1] === :value
    end
  end

  # What: the regex and unaccent renderers on each engine, against a direct `_capability_error` call (the old refusal)
  #   and PostgreSQL's SQL.
  # Expected: on SQLite and MySQL, a `BackendCapabilityError` with the old text for each of the eight lookups; on
  #   PostgreSQL, the SQL each renderer returned.
  # Why: the refusal now goes through the barrier so a trimmed image has code for it; its type and text are what a caller
  #   reads and what the trimmed fixture's `engine_read` lines compare.
  @testset "the regex and unaccent refusals keep their type and text" begin
    why = "PormG does not emulate it: a Julia-side pattern would be PCRE, which disagrees with POSIX syntax on " *
          "backreferences, lazy quantifiers and lookaround."
    lookups = ((_AR_D.regex, :regex, "regex", true), (_AR_D.iregex, :regex, "iregex", true),
               (_AR_D.nregex, :regex, "nregex", true), (_AR_D.niregex, :regex, "niregex", true),
               (_AR_D.iunaccent_contains, :unaccent, "iunaccent_contains", false),
               (_AR_D.iunaccent_exact, :unaccent, "iunaccent_exact", false),
               (_AR_D.niunaccent_contains, :unaccent, "niunaccent_contains", false),
               (_AR_D.niunaccent_exact, :unaccent, "niunaccent_exact", false))
    for conn in (ArMockSQLite(), ArMockMySQL()), (f, feature, op, with_why) in lookups
      old = with_why ? PormG._capability_error(conn, feature, "The $(op) lookup"; why = why) :
                       PormG._capability_error(conn, feature, "The $(op) lookup")
      new = _ar_outcome(() -> f(conn, "name", "\$1"))
      @test (nameof(typeof(conn)), op, new) == (nameof(typeof(conn)), op, (:raised, PormG.BackendCapabilityError, sprint(showerror, old)))
    end
    pg = ArMockPostgres()
    @test _AR_D.regex(pg, "name", "\$1") == "name ~ \$1"
    @test _AR_D.iregex(pg, "name", "\$1") == "name ~* \$1"
    @test startswith(_AR_D.iunaccent_contains(pg, "name", "\$1"), "public.immutable_unaccent(name) ILIKE")
  end
end
