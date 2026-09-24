"""
Dialect renderers, builder function constructors, `parse_choices` and `format_string` accept any
`AbstractString` (#602) — the second half of the `::String`-not-`AbstractString` class #598 opened.

## The contract

#598 fixed the value formatters in `src/Models.jl`. The same class — a `::String` signature, or an
`isa(x, String)` branch, where a `SubString` / `LazyString` should be accepted — remained in
`src/Dialect.jl`, `src/querybuilder/functions.jl`, `src/models/fields.jl` and two non-formatter
sites of `src/Models.jl`. What made this half worse is that most of its sites failed *silently*:

- The text-lookup operators (`contains`, `icontains`, `jcontains`, …) each had a `::String`
  specialised arm beside an untyped generic sibling, so a non-`String` argument was refused for the
  WRONG reason — `InvalidValueError("The value must be a String")`, or, for the JSON family,
  `BackendCapabilityError("… requires PostgreSQL")` *on PostgreSQL*.
- `Power`/`Mod`/`Coalesce`/`Greatest`/`Least`/`NullIf`/`Replace` branch on `isa(x, String)` to wrap
  a column name in `SQLField`; a `SubString` was left raw in the column vector and died later, as
  a `MethodError` deep in `_check_function`, naming nothing the caller wrote.
- `format_string` (model-file generation) returned a non-`String` string RAW — unquoted and
  unescaped — producing source that does not parse, with no error at all.
- `parse_choices` was a bare `MethodError` from `CharField(choices = <SubString>)`, because the
  guard in front of it already admitted any `AbstractString`.

One measurement recorded here because it changes what the PR claims: the operator family never
sees the user's value. Both of its arguments are rendered SQL text — the quoted column and the
`\$N`/`?` placeholder `add_parameter!` returned, both `String` at every call site — so the
`filter("surname__@icontains" => split(...)[1])` shape in the issue reaches a bound parameter long
before Dialect. The direct-dispatch testset below is the mutation gate for that family; the
end-to-end testset is the pin for the documented promise, and passes before and after.

## Two probe types, as in `test_formatter_abstractstring.jl`

`SubString{String}` catches the dispatch defect (a `::String` signature) but is one of the three
string types Base's regex engine accepts, so it is blind to the regex defect; `LazyString` is
neither `String`- nor `SubString{String}`-backed, so it is the only dependency-free way to reach a
`match`/`eachmatch` on a merely-`AbstractString` value. `parse_choices` has both defects; the rest
have only the first. The `"\\0"` prefix on the `SubString` probe gives it a non-zero offset into its
parent, so a view that behaves like a whole `String` cannot mask a bug.

`String(x)`, not `string(x)`, at every conversion site — `string` is the identity for a `LazyString`
(measured in #598; the Base-level assertions live in that file and are not repeated here).

## Mutation gates

Stated per testset. Overall: with the `src/` half of #602 reverted, every testset except the
end-to-end pin has at least one failing assertion. Deterministic, DB-free, no connection.
"""

using Test
using Dates
using PormG
using PormG.QueryBuilder: SQLTypeField, SQLTypeText
using PormG.QueryBuilder: Power, Mod, NullIf, Coalesce, Greatest, Least, Replace, Value

const Mo602 = PormG.Models
const Di602 = PormG.Dialect

# Probes. `_sub602` is a view with a NON-zero offset into its parent (see header); `_lazy602` is a
# `LazyString`, the regex-hostile spelling. Named with the issue number because this file and
# `test_formatter_abstractstring.jl` both load into `Main` under `runtests.jl`.
_sub602(s::String) = SubString("\0" * s, 2)
_lazy602(s::String) = LazyString(s)

# Bare mock connections: the Dialect renderers dispatch on the connection's TYPE only.
struct _MockPg602 <: PormG.PormGPostgres end
struct _MockSl602 <: PormG.PormGSQLite end

@testset "SECTION: Dialect and builder accept any AbstractString (#602)" begin

  @testset "The probes are what this file claims they are (Base)" begin
    @test _sub602("abc") isa SubString{String}
    @test _sub602("abc") == "abc"
    @test _sub602("abc").offset == 1          # a genuine view into "\0abc", not a whole-parent view
    @test _lazy602("abc") isa LazyString
    @test !(_lazy602("abc") isa Union{String, SubString{String}})
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Dialect text-lookup family: direct dispatch on every renderer
  # Each of the 20 operators has a PostgreSQL arm, a SQLite arm and an untyped generic sibling. On
  # PostgreSQL every operator EMITS; on SQLite the four JSONB and the four unaccent operators throw
  # `BackendCapabilityError` and the other twelve emit. The assertion is exact on both counts: the
  # `SubString`/`LazyString` spelling must produce the SAME text, or the SAME exception type, as
  # the `String` spelling — never the generic sibling's wrong-reason refusal.
  # Mutation gate: re-narrow any specialised arm to `::String` and its `SubString` row on
  # PostgreSQL throws `InvalidValueError` (LIKE family) or `BackendCapabilityError` (JSON family)
  # instead of returning text; the SQLite emit rows fail the same way.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "Text-lookup renderers dispatch on any AbstractString column and placeholder" begin
    ops = [:jcontains, :has_key, :has_any_keys, :has_keys,
           :contains, :icontains, :iunaccent_contains, :iunaccent_exact,
           :startswith, :istartswith, :endswith, :iendswith,
           :ncontains, :nicontains, :niunaccent_contains, :niunaccent_exact,
           # #604 added the negated case-insensitive prefix/suffix twins. They are NOT PG-only: like
           # `nicontains`, they emit on SQLite through the pormg_lower UDF (#78).
           :nstartswith, :nistartswith, :nendswith, :niendswith]
    json_ops = Set([:jcontains, :has_key, :has_any_keys, :has_keys])
    sqlite_pg_only = union(json_ops, Set([:iunaccent_contains, :iunaccent_exact,
                                          :niunaccent_contains, :niunaccent_exact]))
    @test length(ops) == 20

    col = "\"drivers\".\"surname\""
    for op in ops
      f = getfield(Di602, op)

      # PostgreSQL: every operator emits, and the placeholder spelling is `$1`.
      pg_base = f(_MockPg602(), col, "\$1")
      @test pg_base isa String
      @test occursin("\$1", pg_base)
      @test f(_MockPg602(), _sub602(col), _sub602("\$1")) == pg_base
      @test f(_MockPg602(), _lazy602(col), _lazy602("\$1")) == pg_base
      # Mixed spellings — one argument wide, the other a String — must not fall between arms.
      @test f(_MockPg602(), _sub602(col), "\$1") == pg_base
      @test f(_MockPg602(), col, _sub602("\$1")) == pg_base

      # SQLite: the PG-only eight throw the SAME capability error on every spelling; the rest emit.
      if op in sqlite_pg_only
        @test_throws PormG.BackendCapabilityError f(_MockSl602(), col, "?")
        @test_throws PormG.BackendCapabilityError f(_MockSl602(), _sub602(col), _sub602("?"))
        @test_throws PormG.BackendCapabilityError f(_MockSl602(), _lazy602(col), _lazy602("?"))
      else
        sl_base = f(_MockSl602(), col, "?")
        @test sl_base isa String
        @test occursin("?", sl_base)
        @test f(_MockSl602(), _sub602(col), _sub602("?")) == sl_base
        @test f(_MockSl602(), _lazy602(col), _lazy602("?")) == sl_base
      end

      # The generic sibling is still the guard for a non-string placeholder — on BOTH backends,
      # which is the shape the fix must not lose: a `PormGPostgres` mock is a `PormGAbstractType`.
      # Exact type per family: the four JSONB generics refuse with `BackendCapabilityError`, every
      # other generic (the unaccent four included) with `InvalidValueError`.
      generic_err = op in json_ops ? PormG.BackendCapabilityError : PormG.InvalidValueError
      @test_throws generic_err f(_MockPg602(), col, 42)
      @test_throws generic_err f(_MockSl602(), col, 42)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Text-lookup family end to end: the documented promise, pinned
  # `docs/src/read/filters_and_aggregates.md` → "Filter Values from Web Frameworks" promises that
  # a `SubString` filter value needs no conversion. The value is bound by `add_parameter!` before
  # Dialect ever runs, so this testset passes before and after #602 — it is NOT a mutation gate for
  # this PR. It is here so the doc claim has a test that would fail if the binding path regressed.
  # A mock connection under its OWN config key, never `config["default"]`.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "A SubString filter value reaches the LIKE renderer as a bound parameter" begin
    PormG.config["dialect_abstractstring_602_pg"] = PormG.Configuration.Settings(
      connections = _MockPg602(), change_data = true)
    PormG.config["dialect_abstractstring_602_sl"] = PormG.Configuration.Settings(
      connections = _MockSl602(), change_data = true)
    drivers = Mo602.Model("drivers",
      id      = Mo602.IDField(),
      surname = Mo602.CharField(max_length = 100),
      points  = Mo602.FloatField(),
    )

    # The issue's own motivating shape: a search term straight out of `split`.
    term = split("senna hamilton", " ")[1]
    @test term isa SubString{String}

    try
      for key in ("dialect_abstractstring_602_pg", "dialect_abstractstring_602_sl")
        drivers.connect_key = key
        baseline = drivers.objects.filter("surname__@icontains" => "senna").list(show_query = :dict)
        from_split = drivers.objects.filter("surname__@icontains" => term).list(show_query = :dict)
        @test from_split[:sql_text] == baseline[:sql_text]
        @test from_split[:parameters] == baseline[:parameters]
        @test baseline[:parameters] == ["%senna%"]     # the wildcard decoration happened on the value
        # `startswith` / `endswith`, the other two wildcard shapes.
        @test drivers.objects.filter("surname__@startswith" => term).list(show_query = :dict)[:parameters] == ["senna%"]
        @test drivers.objects.filter("surname__@endswith" => term).list(show_query = :dict)[:parameters] == ["%senna"]
      end
    finally
      # `finally`, so an error mid-block cannot leak the keys into the shared `runtests.jl` process.
      delete!(PormG.config, "dialect_abstractstring_602_pg")
      delete!(PormG.config, "dialect_abstractstring_602_sl")
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Function constructors: `isa(x, AbstractString)`, wrap through `String(x)`
  # A string argument to `Power`/`Mod`/`Coalesce`/`Greatest`/`Least`/`NullIf`/`Replace` means "a
  # column"; the constructor wraps it in `SQLField`. The old `isa(x, String)` left a `SubString`
  # raw, so the node built fine and then failed at render time inside `_check_function`. `Replace`'s
  # search/replacement strings are LITERALS (`Value`), the one place the wrap is a `SQLText`.
  # Mutation gate: revert any one branch to `isa(x, String)` and its `SubString` row below is a raw
  # `SubString` in `.column` (the `isa SQLTypeField` assertion fails), and the render row raises
  # `MethodError` instead of building SQL.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "Function constructors wrap any AbstractString column in SQLField" begin
    # Two-argument scalar functions: both positions are wrapped.
    for ctor in (Power, Mod, NullIf)
      base = ctor("points", "wins")
      wide = ctor(_sub602("points"), _sub602("wins"))
      lazy = ctor(_lazy602("points"), _lazy602("wins"))
      for node in (wide, lazy)
        @test node.function_name == base.function_name
        @test all(c -> c isa SQLTypeField, node.column)
        @test [c.field for c in node.column] == [c.field for c in base.column] == ["points", "wins"]
        @test all(c -> c.field isa String, node.column)   # `String(x)`, not the probe passed through
      end
      # A number operand is a literal (#705). It used to be stored raw, and that raw `2` is what
      # `_check_function` had no arm for: `values("x" => Power("points", 2))` died with a
      # `MethodError`. So this row asserted the defect's shape; it now asserts the `Value` wrap.
      @test ctor(_sub602("points"), 2).column[2] isa SQLTypeText
      @test ctor(_sub602("points"), 2).column[2].field == 2
    end

    # Variadic: every string element is wrapped; a number is a `Value` literal (#705).
    for ctor in (Coalesce, Greatest, Least)
      base = ctor("points", "wins", 0)
      wide = ctor(_sub602("points"), _sub602("wins"), 0)
      @test wide.function_name == base.function_name
      @test wide.column[1] isa SQLTypeField && wide.column[1].field == "points"
      @test wide.column[2] isa SQLTypeField && wide.column[2].field == "wins"
      @test wide.column[3] isa SQLTypeText && wide.column[3].field == 0
      @test ctor(_lazy602("points")).column[1].field == "points"
    end

    # `Replace`: column → `SQLField`, find/replace → `Value` (a `SQLText` literal).
    base = Replace("surname", "-", " ")
    wide = Replace(_sub602("surname"), _sub602("-"), _sub602(" "))
    @test wide.column[1] isa SQLTypeField && wide.column[1].field == "surname"
    @test wide.column[2] isa SQLTypeText && wide.column[2].field == "-"
    @test wide.column[3] isa SQLTypeText && wide.column[3].field == " "
    @test wide.column[2].field isa String && wide.column[3].field isa String
    @test typeof(base.column[2]) == typeof(wide.column[2])

    # Render one of each shape end to end: same SQL and same bound parameters as the `String` build.
    PormG.config["dialect_abstractstring_602_fn"] = PormG.Configuration.Settings(
      connections = _MockPg602(), change_data = true)
    drivers = Mo602.Model("drivers",
      id      = Mo602.IDField(),
      surname = Mo602.CharField(max_length = 100),
      points  = Mo602.FloatField(),
      wins    = Mo602.IntegerField(),
    )
    drivers.connect_key = "dialect_abstractstring_602_fn"

    try
      # Literal operands are spelled `Value(2)`, as the docs do (`functions_and_dates.md`); a bare
      # `Int` in a function's column vector has no render arm, and that is not this issue's.
      pow_base = drivers.objects.values("p" => Power("points", Value(2))).list(show_query = :dict)
      pow_wide = drivers.objects.values("p" => Power(_sub602("points"), Value(2))).list(show_query = :dict)
      @test pow_wide[:sql_text] == pow_base[:sql_text]
      @test pow_wide[:parameters] == pow_base[:parameters] == [2]
      @test occursin("POWER", pow_base[:sql_text])

      rep_base = drivers.objects.values("s" => Replace("surname", "-", " ")).list(show_query = :dict)
      rep_wide = drivers.objects.values("s" => Replace(_sub602("surname"), _sub602("-"), _sub602(" "))).list(show_query = :dict)
      @test rep_wide[:sql_text] == rep_base[:sql_text]
      @test rep_wide[:parameters] == rep_base[:parameters] == ["-", " "]

      coal_base = drivers.objects.values("c" => Coalesce("points", "wins", Value(0))).list(show_query = :dict)
      coal_wide = drivers.objects.values("c" => Coalesce(_sub602("points"), _sub602("wins"), Value(0))).list(show_query = :dict)
      @test coal_wide[:sql_text] == coal_base[:sql_text]
      @test coal_wide[:parameters] == coal_base[:parameters]
    finally
      delete!(PormG.config, "dialect_abstractstring_602_fn")
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # `ISNULL`: the rendered column text is an `AbstractString`
  # `ISNULL(v, ::Bool)` receives the already-rendered column and appends `IS [NOT] NULL`; it also
  # refuses a function expression (`(` in the text) with a `FilterError`. Both behaviours must be
  # spelling-independent.
  # Mutation gate: re-narrow `v::String` and the `SubString` rows are a `MethodError`.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "ISNULL accepts any AbstractString column text" begin
    col = "\"drivers\".\"surname\""
    for probe in (identity, _sub602, _lazy602)
      @test PormG.QueryBuilder.ISNULL(probe(col), true)  == "$(col) IS NULL"
      @test PormG.QueryBuilder.ISNULL(probe(col), false) == "$(col) IS NOT NULL"
      @test_throws PormG.FilterError PormG.QueryBuilder.ISNULL(probe("LOWER($(col))"), true)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # `parse_choices` and `CharField(choices = …)`: both defects in one site
  # The `CharField` guard admits any `AbstractString` and hands it to `parse_choices`, which was
  # `::String`-only (dispatch defect) and runs `eachmatch` on the value (regex defect). The
  # `SubString` probe catches the first, the `LazyString` probe the second — see the header.
  # Mutation gate: re-narrow the signature and the `_sub602` rows are a `MethodError`; keep the
  # signature but drop the `String(…)` before `eachmatch` and only the `_lazy602` rows fail.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "parse_choices and CharField(choices=…) accept any AbstractString" begin
    spec = "((\"a\",\"Alpha\"),(\"b\",\"Beta\"))"
    base = Mo602.parse_choices(spec)
    @test length(base) == 2                 # the baseline itself parses two pairs
    @test Mo602.parse_choices(_sub602(spec)) == base
    @test Mo602.parse_choices(_lazy602(spec)) == base
    # Keys and values come back as `String`s regardless of the input spelling.
    @test all(p -> p[1] isa String && p[2] isa String, Mo602.parse_choices(_lazy602(spec)))

    # Through the public constructor, where the guard already admitted the wide spelling.
    f_base = Mo602.CharField(choices = spec)
    @test Mo602.CharField(choices = _sub602(spec)).choices == f_base.choices
    @test Mo602.CharField(choices = _lazy602(spec)).choices == f_base.choices

    # The format error is the same taxonomy type on every spelling (not a `MethodError`).
    bad = "((\"a\",\"Alpha\",\"extra\"))"
    @test_throws PormG.FieldValidationError Mo602.parse_choices(bad)
    @test_throws PormG.FieldValidationError Mo602.parse_choices(_sub602(bad))
    @test_throws PormG.FieldValidationError Mo602.parse_choices(_lazy602(bad))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # `format_string`: the silent, destructive one
  # Model-file generation quotes and escapes a string so a live column name like `say "hi"` or
  # `cost$usd` becomes a parseable literal. The old `x isa String` sent every other string type
  # down the `else` branch RAW. A non-string still passes through untouched — that branch is the
  # contract for numbers, `nothing` and symbols reaching the same writer.
  # Mutation gate: revert to `x isa String` and the probe rows return the bare probe (unquoted).
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "format_string quotes and escapes any AbstractString" begin
    raw = "say \"hi\" cost\$usd \\ end"
    base = Mo602.format_string(raw)
    @test base == "\"say \\\"hi\\\" cost\\\$usd \\\\ end\""
    @test Meta.parse(base) == raw                 # the literal round-trips through the parser
    @test Mo602.format_string(_sub602(raw)) == base
    @test Mo602.format_string(_lazy602(raw)) == base
    @test Mo602.format_string(_sub602(raw)) isa String
    # Non-strings pass through, unchanged and unwrapped.
    @test Mo602.format_string(nothing) === nothing
    @test Mo602.format_string(3) === 3
    @test Mo602.format_string(:sym) === :sym
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Removals pinned
  # `Dialect.VALUE` (six methods, zero callers, and the `String` arms interpolated an UNESCAPED
  # literal into SQL) and `format_timezone_sql(::DateTime, ::String)` are deleted rather than
  # widened. These rows fail if either comes back. The 1-arg `DateTime` arm — the live one — still
  # canonicalizes to UTC.
  #
  # CORRECTION (#607): the two-argument arm was deleted as having "zero callers since #79", and its
  # own comment naming a migration-planner caller was dismissed as stale. The caller existed —
  # `_get_temporary_default_value` reached it through the `field.formatter` SLOT, invisible to a
  # grep by function name — so from #602's merge every NOT NULL temporal `ADD COLUMN` raised
  # `MethodError` until #607 rewrote that line to the one-argument form the insert path uses. The
  # arm stays deleted (this pin holds); the lesson is to grep `.formatter(` shapes, not names.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "Dead String-typed methods are gone, live siblings intact" begin
    @test !isdefined(Di602, :VALUE)
    @test !hasmethod(Mo602.format_timezone_sql, Tuple{DateTime, String})
    @test !hasmethod(Mo602.format_timezone_sql, Tuple{DateTime, AbstractString})
    @test Mo602.format_timezone_sql(DateTime(2021, 3, 26, 6)) == "2021-03-26T06:00:00.000+00:00"
  end
end
