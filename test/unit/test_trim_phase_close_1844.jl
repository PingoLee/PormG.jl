# ============================================================
# test/unit/test_trim_phase_close_1844.jl
#
# CONTRACT being tested:
#   #1844 typed two paths for a trimmed build, and neither changes what it returns or raises:
#   - `_locate_filter_refusal` reads its type label at the types its callers pass (`_opt_label`): every located refusal
#     carries the same type, message and location as with the old `_opt_label(x) = x === nothing ? nothing : string(x)`.
#   - `ArrayFormatter` formats each element at the (formatter, kind) pair's types (`_array_element_text`): every literal,
#     and every refusal's type, message and `kind`, equals the old element loop's, for every element field type, the
#     open arm included.
#   Each is compared against a copy of the old code kept here. The array lookups' SQL and parameters on three engines are
#   `test_lookup_bind_matrix_1599.jl`'s recorded cells, which this change must not move.
#
# Hermetic: no database.
#
# Run: julia --project=test/integration test/unit/test_trim_phase_close_1844.jl
# ============================================================

using Test
isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))
using PormG
using Dates: Date, DateTime
using PormG.Decimals: Decimal

const _TPC_QB = PormG.QueryBuilder
const _TPC_M = PormG.Models

# ── The old code, verbatim but for names ─────────────────────────────────────────────────────────

_tpc_old_opt_label(x) = x === nothing ? nothing : string(x)

function _tpc_old_locate(@nospecialize(e), @nospecialize(label), @nospecialize(type_label); subject::AbstractString = "field")
  QB = _TPC_QB
  e isa PormG.InvalidValueError || rethrow(e)
  named = label isa AbstractString ? String(label) : label isa Symbol ? string(label) :
          label isa QB.CTEReference ? "CTE(\"$(label.name)\", \"$(label.path)\")" :
          label isa QB.JoinedReference ? sprint(show, label) : nothing
  throw(subject == "field" && named !== nothing ?
          PormG.with_location(e; op = "filter", field = named, field_type = _tpc_old_opt_label(type_label)) :
        subject == "field" ?
          PormG.with_location(e; op = "filter on an expression", field_type = _tpc_old_opt_label(type_label)) :
          PormG.with_location(e; op = named === nothing ? "filter on a $(subject)" :
                                                          "filter on the `$(named)` $(subject)",
                              field_type = _tpc_old_opt_label(type_label)))
end

function _tpc_old_array_format(f::_TPC_M.ArrayFormatter, value)
  M = _TPC_M
  (value === missing || value === nothing) && return missing
  value isa M.PormGArrayLiteral && return value
  elems = value isa AbstractString ?
    Any[e === nothing ? nothing : M.pg_array_element_value(f.kind, e) for e in M.parse_pg_array_literal(value)] :
    M._pg_array_elements(value)
  f.size !== nothing && length(elems) > f.size &&
    throw(PormG.InvalidValueError("this ArrayField holds at most $(f.size) elements (size = $(f.size)), got $(length(elems)).", :range))
  texts = Vector{Union{Nothing, String}}(undef, length(elems))
  for (i, el) in enumerate(elems)
    if el === nothing || el === missing
      f.base.null ||
        throw(PormG.InvalidValueError("element $i is null, and this ArrayField's base field does not allow null elements (declare it with null = true).", :other))
      texts[i] = nothing
      continue
    end
    (el isa Union{AbstractArray, Tuple} && !(el isa AbstractString)) &&
      throw(PormG.InvalidValueError("element $i is a $(typeof(el)): an ArrayField holds a one-dimensional array, so an element cannot be a collection.", :type))
    texts[i] = try
      formatted = M.apply_formatter(f.base.formatter, el)
      source = f.kind isa PormG.CDecimal && el isa Union{Float16, Float32, Float64} ? string(el) : formatted
      M.pg_array_element_text(f.kind, M.pg_array_element_value(f.kind, source))
    catch e
      (e isa InterruptException || e isa StackOverflowError) && rethrow()
      reason = e isa PormG.InvalidValueError ? e.reason :
               e isa MethodError ? "a $(typeof(el)) is not a valid $(M._pg_kind_label(f.kind)) value" : rethrow()
      throw(PormG.InvalidValueError("element $i of the array: $(rstrip(reason, '.')).",
                                    e isa PormG.InvalidValueError ? e.kind : :type))
    end
  end
  return M.PormGArrayLiteral(M.print_pg_array_literal(texts))
end

# What a call returned or raised, as comparable data: a value, or the error's type, message and every location slot.
function _tpc_outcome(thunk)
  try
    v = thunk()
    return (:value, v isa _TPC_M.PormGArrayLiteral ? ("literal", v.value) : v)
  catch e
    e isa PormG.InvalidValueError &&
      return (:error, PormG.InvalidValueError, e.msg, e.kind, e.reason, e.op, e.model, e.field, e.field_type, e.row)
    return (:error, typeof(e), sprint(showerror, e))
  end
end

@testset "#1844: the located refusal and the array element path, typed, equal the old code" begin
  # What: `_locate_filter_refusal` with every label type its callers pass and a few they do not, under each subject.
  # Expected: the same `InvalidValueError` (message, kind, reason, op, field, field_type) as the old locator; anything that
  #   is not an `InvalidValueError` rethrown untouched.
  # Why: the typed label is the trimmed fix (#1844); under the JIT nothing may change, error text included.
  @testset "_locate_filter_refusal: every label and subject" begin
    cte = _TPC_QB.CTEReference(name = "laps", path = "driverid")
    joined = _TPC_QB.JoinedReference("j", "round", false)
    labels = Any["year", SubString("year_x", 1, 4), :year, nothing, cte, joined, 42]
    type_labels = Any[nothing, "IntegerField", SubString("DateFieldX", 1, 9), :DateField, 7, PormG.CInt64()]
    n = 0
    for label in labels, tl in type_labels, subject in ("field", "alias", "annotation")
      err = PormG.InvalidValueError("The value is not a whole number", :type)
      new = _tpc_outcome(() -> _TPC_QB._locate_filter_refusal(err, label, tl; subject = subject))
      old = _tpc_outcome(() -> _tpc_old_locate(err, label, tl; subject = subject))
      @test new == old
      @test new[1] === :error && new[2] === PormG.InvalidValueError
      n += 1
    end
    @test n == length(labels) * length(type_labels) * 3
    # A label the old code printed with `string`: the open arm prints it the same way.
    @test _TPC_QB._opt_label(PormG.CInt64()) == string(PormG.CInt64())
    @test _TPC_QB._opt_label(:DateField) == "DateField"
    @test _TPC_QB._opt_label(nothing) === nothing
    s = "IntegerField"
    @test _TPC_QB._opt_label(s) === s                                   # a String is the label itself
    # Not an InvalidValueError: rethrown as the same object.
    boom = ErrorException("boom")
    # Called from a `catch`, as every caller does (`rethrow` needs one).
    @test try
      try throw(boom) catch e; _TPC_QB._locate_filter_refusal(e, "year", "IntegerField") end
      nothing
    catch e2
      e2
    end === boom
  end

  # What: `ArrayFormatter` over every element field type, with valid values, refused values, nulls, nested collections,
  #   tuples, an array-literal String, a size bound, and a base/kind pair no arm names (the open arm).
  # Expected: each literal, or each refusal's type, message, reason and kind, equals the old element loop's.
  # Why: the typed walk replaces `apply_formatter` + the untyped element conversion; a different text would change the
  #   bound literal of every array write and lookup.
  @testset "ArrayFormatter: every element field type, the old loop's literal or refusal" begin
    M = _TPC_M
    cases = Pair{Any, Vector{Any}}[
      M.IntegerField() => Any[[12, 31], Int32[1, 2], [1.0, 2.0], [1.5], ["7"], ["x"], [true], [nothing], Any[1, "2"], (3, 4),
                              "{5,6}", [[1]], Int[], [typemax(Int64)]],
      M.IntegerField(null = true) => Any[[1, nothing], Any[nothing, missing]],
      M.BigIntegerField() => Any[[typemax(Int64), -1], ["12"], [2.5]],
      M.FloatField() => Any[[1.1, 2], [1.0f0], ["3.25"], [Decimal(1, 125, -2)], ["nan"]],
      M.DecimalField(max_digits = 6, decimal_places = 2) => Any[[1.1, 2], [Decimal(0, 250, -2)], ["3.141"], [1.5f0], ["x"]],
      M.CharField(max_length = 5) => Any[["a", "b,c"], ["toolong"], [12], ["with\"quote"], [SubString("abc", 1, 2)]],
      M.TextField() => Any[["soft", "medium"], [""], ["NULL"], [:sym]],
      M.EmailField() => Any[["a@b.co"]],
      M.BooleanField() => Any[[true, false], ["t"], [1], [0]],
      M.DateField() => Any[[Date(2008, 5, 25)], ["2008-05-25"], ["2008-02-30"], [DateTime(2008, 5, 25, 1)]],
      M.DateTimeField() => Any[[DateTime(2008, 5, 25, 14, 0)], ["2008-05-25T14:00:00"], ["x"]],
      M.UUIDField() => Any[["6ba7b810-9dad-11d1-80b4-00c04fd430c8"], ["nope"]],
    ]
    n = 0
    for (base, values) in cases
      af = M.ArrayField(base).formatter::M.ArrayFormatter
      for size in (nothing, 1), v in values
        f = M.ArrayFormatter(af.base, af.kind, size)
        new = _tpc_outcome(() -> f(v))
        old = _tpc_outcome(() -> _tpc_old_array_format(f, v))
        @test new == old
        n += 1
      end
    end
    @test n > 100
    # The open arm: a base whose formatter is not the one its kind pairs with (an integer field read as text).
    f = M.ArrayFormatter(M.ArrayField(M.IntegerField()).formatter.base, PormG.CText(), nothing)
    for v in Any[[12], ["x"], [1.5]]
      @test _tpc_outcome(() -> f(v)) == _tpc_outcome(() -> _tpc_old_array_format(f, v))
    end
  end

  # What: which formatter each element field type declares, against the arm `_array_element_text` names for its kind.
  # Expected: every element field type's default formatter is one of the six the walk names, so its elements take a
  #   static arm, not the open one.
  # Why: a field type whose formatter changed would silently fall back to the run-time arm, and the trimmed array lookups
  #   would stop again with no test failing.
  @testset "every element field type takes a typed arm" begin
    M = _TPC_M
    arms = Dict(PormG.CInt32 => M.format_number_sql, PormG.CInt64 => M.format_number_sql, PormG.CFloat64 => M.format_number_sql,
                PormG.CDecimal => M.format_number_sql, PormG.CVarChar => M.format_text_sql, PormG.CText => M.format_text_sql,
                PormG.CDate => M.format_date_sql, PormG.CDateTime => M.format_timezone_sql, PormG.CBool => M.format_bool_sql,
                PormG.CUUID => M.format_uuid_sql)
    for base in (M.CharField(max_length = 3), M.URLField(), M.SlugField(), M.TextField(), M.EmailField(), M.IntegerField(),
                 M.BigIntegerField(), M.FloatField(), M.DecimalField(max_digits = 5, decimal_places = 1), M.BooleanField(),
                 M.DateField(), M.DateTimeField(), M.UUIDField())
      af = M.ArrayField(base).formatter::M.ArrayFormatter
      @test af.base.formatter === arms[typeof(af.kind)]
    end
    @test length(arms) == length(Base.uniontypes(PormG._ArrayElementKind))
  end
end
