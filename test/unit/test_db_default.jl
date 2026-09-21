"""
`db_default` — a declarable, database-side expression column DEFAULT (#496).

#475 made a non-literal column `DEFAULT` behave uniformly by **dropping** it on every column type
and both engines. That closed a correctness bug (a textual column silently kept the expression as a
quoted literal, and re-applying it stored that text in every row) but discarded the information:
`inspectdb` could not round-trip such a column, `makemigrations` could never propose removing a
default it could not see, and a user had no way to express one at all. #496 is the other half —
Django's `Field.db_default` — and this file is its contract.

**The shape, and why the pin is in the VALUE'S TYPE.** A bare `String` asserts the expression renders
on both engines and is therefore accepted only for the closed vocabulary `PORTABLE_DB_DEFAULTS`; a
`NamedTuple` over `(:postgres, :sqlite)` pins it, with an explicit `nothing` as the per-engine
opt-out. Encoding the pin in the type rather than in a second `db_default_engine` slot makes three
bad states unrepresentable instead of merely validated — an engine with no text, text with no
engine, and an unknown engine name — and it keeps the `Model_to_str` round trip free, because a
NamedTuple interpolates into valid Julia source that parses back to an equal value.

**Where PormG departs from Django, deliberately.** Django's `db_default` takes an expression OBJECT
compiled per backend, so portability falls out by construction and the diff compares objects. PormG
takes the raw string, which is LESS magic — nothing is inferred — at the cost that PormG cannot know
which engines an arbitrary expression is valid on. The vocabulary plus the pin is what buys back the
guarantee that a models file never emits DDL the target database will reject.

**The two properties worth naming, because a regression in either is silent:**

  * **convergence** — a column compiled from a declaration must equal the same column read back from
    the catalog, or `makemigrations` re-plans it forever (the #325 → #503 bug class, seen seven
    times). `canonical_db_default` is applied to BOTH sides, through one function, which is what
    makes that true;
  * **the one asymmetry** — a live expression default the model does not mention is deliberately NOT
    a difference (`_defaults_equal`), so upgrading to #496 never proposes `DROP DEFAULT` against a
    database default PormG was never asked to manage.

Fully hermetic. `PormGPostgres`/`PormGSQLite` are abstract markers, so a bare marker struct is a
sufficient `conn` for both engines — no PostgreSQL server and no temp file. The live-database half
is `test/integration/test_importers_introspection.jl`.

    julia --project=test/integration test/unit/test_db_default.jl
"""

using Test
using PormG
using PormG: Migrations, Dialect
using PormG.Models
using PormG: PORTABLE_DB_DEFAULTS, canonical_db_default, db_default_is_portable,
             is_valid_db_default_sql
using PormG: NoDefault, LiteralDefault, ExpressionDefault, ColumnSpec, ColumnDelta, column_delta
using PormG.ConnectionPool: SQLiteConnectionPool, fetch, close_pool!
using InteractiveUtils: subtypes
using Logging
using SQLite      # loads the weakdep extension the temp-file cases below need

struct MockPg496 <: PormG.PormGPostgres end
struct MockSl496 <: PormG.PormGSQLite end
const PG496 = MockPg496()
const SL496 = MockSl496()

# A single quote, built rather than escaped — the surrounding string literals in this file are
# already dense with escapes and a stray `\'` is hard to read in a SQL fragment.
#
# PREFIXED, and not cosmetically: `runtests.jl` includes every unit file into one `Main`, where
# `using PormG` has already bound the exported query primitive `Q`. A bare `const Q` here is a
# "cannot declare Main.Q constant; it was already declared as an import" error — which the file
# does NOT hit when run standalone, so the suite is the only place it shows up.
const DBD_Q = Char(39)

# ─────────────────────────────────────────────────────────────────────────────
# The canonicaliser: one normalisation, applied to both sides of the diff
# Every step here is FORCED by a measured engine behaviour, not chosen for tidiness, so each
# assertion names the behaviour it exists for. Idempotence is the load-bearing one:
# `Model_to_str` → reload → re-canonicalise is a real cycle.
# ─────────────────────────────────────────────────────────────────────────────
@testset "canonical_db_default normalises, and is idempotent (#496)" begin
    # Case folding, and ONLY for the vocabulary. SQLite echoes the source text including its case
    # (`PRAGMA table_info`), PostgreSQL's deparser always prints these two upper case — so folding
    # is what lets one declaration converge against either catalog.
    @test canonical_db_default("current_timestamp") == "CURRENT_TIMESTAMP"
    @test canonical_db_default("  CURRENT_DATE  ") == "CURRENT_DATE"
    # An opaque expression keeps its case: a quoted identifier inside it is case-significant on both
    # engines, so folding one would change what the DDL means.
    @test canonical_db_default("MyFunc(\"MyCol\")") == "MyFunc(\"MyCol\")"

    # Balanced outer parens are stripped, because SQLite's grammar requires `DEFAULT (expr)` for
    # anything outside its `literal-value` set — so PormG ADDS a layer when it renders — while
    # `PRAGMA table_info` reports the text back with that layer already removed. Measured on SQLite
    # 3.53.4: `DEFAULT (abs(random()) % 10)` reads back as `abs(random()) % 10`. Stripping here makes
    # the renderer's addition and the catalog's removal exact inverses.
    @test canonical_db_default("(abs(random()) % 10)") == "abs(random()) % 10"
    @test canonical_db_default("((1))") == "1"

    # …but only BALANCED outer parens. `(a) + (b)` is not one group, and the naive
    # `^\((.+)\)$` this shares a predicate with would rewrite it to `a) + (b` — a mangled
    # expression rather than an unrecognised one. Same defect `_wrapped_in_parens` was written for.
    @test canonical_db_default("(a) + (b)") == "(a) + (b)"
    # Parens inside a string literal do not count either.
    @test canonical_db_default("($(DBD_Q)a)b$(DBD_Q))") == "$(DBD_Q)a)b$(DBD_Q)"

    # A `)` inside a QUOTED IDENTIFIER does not close the group either — the same rule as for a
    # string literal. Found in review: the relocated predicate tracked only `'…'`, so `("a)b")` was
    # not recognised as one group, the wrapper survived, SQLite's renderer added a second one, and
    # the catalog then reported back a different string than was declared — a permanent delta.
    @test canonical_db_default("(\"a)b\")") == "\"a)b\""

    # IDEMPOTENCE. Without it the generated-file cycle would drift a little on every regeneration,
    # which is the churn class wearing a different hat.
    for s in ["( (a) )", "  CURRENT_DATE ", "(abs(random()) % 10)", "(a) + (b)", "now()",
              "concat($(DBD_Q)a$(DBD_Q)::text, $(DBD_Q)b$(DBD_Q)::text)",
              # …including past any plausible nesting. The strip loop is unbounded on purpose: it
              # is strictly decreasing so it cannot spin, and a bound would make exactly this input
              # reduce further on a second call. Found in review, where the bound was 8.
              "(((((((((1)))))))))"]
        @test canonical_db_default(canonical_db_default(s)) == canonical_db_default(s)
    end
    @test canonical_db_default("(((((((((1)))))))))") == "1"

    # Portability is decided on the CANONICAL form, so the spelling a user types does not change
    # the answer.
    @test db_default_is_portable("current_timestamp")
    @test db_default_is_portable("(CURRENT_DATE)")
    @test !db_default_is_portable("now()")
    @test !db_default_is_portable("gen_random_uuid()")
    # The vocabulary is exactly two, and the shortness is the design rather than an oversight — an
    # entry has to round-trip identically through BOTH catalogs or a column carrying it churns on
    # one of them. Pinned so that growing it is a deliberate act with a reason attached.
    @test PORTABLE_DB_DEFAULTS == ("CURRENT_TIMESTAMP", "CURRENT_DATE")
end

# ─────────────────────────────────────────────────────────────────────────────
# The well-formedness guard: a typo must not silently rewrite the statement around it
# NOT a security boundary, and it does not pretend to be one — the trust question was settled for
# #496 explicitly (a db_default is author-supplied schema text, the category db_table/db_column
# already occupy). What it catches is three ways a typo stops being a typo, all invisible in the
# generated DDL. Both polarities are asserted for each: the token must be refused OUTSIDE a literal
# and must stay legal INSIDE one, or the guard would reject ordinary expressions.
# ─────────────────────────────────────────────────────────────────────────────
@testset "is_valid_db_default_sql rejects statement-breaking text, not ordinary SQL (#496)" begin
    # Accepted: real expressions from both engines' catalogs.
    for ok in ["now()", "CURRENT_TIMESTAMP", "abs(random()) % 10",
               "concat($(DBD_Q)a$(DBD_Q)::text, $(DBD_Q)b$(DBD_Q)::text)", "nextval($(DBD_Q)s$(DBD_Q)::regclass)",
               "gen_random_uuid()", "($(DBD_Q)a$(DBD_Q)) || ($(DBD_Q)b$(DBD_Q))", "lower(hex(randomblob(16)))"]
        @test is_valid_db_default_sql(ok)
    end

    # Refused, and each for a distinct failure of the SURROUNDING statement rather than of itself:
    #   a `;` splits one DDL statement into two, and PostgreSQL's simple query protocol runs both;
    #   a `--` or `/*` comments out the rest of the column list, so a CREATE TABLE silently loses
    #   every column after this one;
    #   an unterminated quote swallows the remainder the same way;
    #   unbalanced parens put SQLite's added layer in the wrong place.
    @test !is_valid_db_default_sql("1; DROP TABLE lap_note")
    @test !is_valid_db_default_sql("5 -- boom")
    @test !is_valid_db_default_sql("5 /* boom")
    @test !is_valid_db_default_sql("$(DBD_Q)unterminated")
    @test !is_valid_db_default_sql("\"unterminated")
    @test !is_valid_db_default_sql("((1)")
    @test !is_valid_db_default_sql("1)")
    @test !is_valid_db_default_sql("")
    @test !is_valid_db_default_sql("   ")
    # A TOP-LEVEL comma injects a whole extra column definition into the CREATE TABLE it sits in,
    # which is the same class of damage as a `;` and at least as easy to type. Added in review —
    # it was the one statement-breaking character the first version of this scanner let through.
    @test !is_valid_db_default_sql("0, evil TEXT DEFAULT $(DBD_Q)x$(DBD_Q)")
    @test !is_valid_db_default_sql("1,2")
    # …but a comma INSIDE a call's parentheses is where every legitimate one lives, and the walk
    # must not see those. Without this the guard would refuse `concat(…)` and push users back to
    # `default=`, which is the corrupting slot.
    @test is_valid_db_default_sql("concat($(DBD_Q)a$(DBD_Q), $(DBD_Q)b$(DBD_Q))")
    @test is_valid_db_default_sql("coalesce(a, b, c)")
    @test is_valid_db_default_sql("$(DBD_Q)a,b$(DBD_Q)")   # …or inside a literal
    # …or inside an ARRAY constructor's BRACKETS, which is why `depth` counts `[` and `]` and not
    # only parentheses. `ARRAY['a','b']` is exactly what PostgreSQL's deparser prints for such a
    # default, so the first version of the comma rule refused a value a real catalog produces —
    # and the docstring justified itself by claiming every legitimate comma sits inside a function
    # call's parentheses, which is false. Found in the delta review.
    @test is_valid_db_default_sql("ARRAY[$(DBD_Q)a$(DBD_Q)::text, $(DBD_Q)b$(DBD_Q)::text]")
    @test is_valid_db_default_sql("ARRAY[1, 2, 3]")
    @test is_valid_db_default_sql("(ARRAY[1, 2])[1]")
    # …and an unbalanced bracket is refused for the same reason an unbalanced paren is.
    @test !is_valid_db_default_sql("ARRAY[1, 2")
    @test !is_valid_db_default_sql("1]")

    # THE assertion that stops the guard being useless: all three tokens are legal DATA, and an
    # expression that contains one as a literal must pass. A guard that failed these would refuse
    # ordinary defaults and push users straight back to `default=`.
    @test is_valid_db_default_sql("$(DBD_Q)a;b$(DBD_Q)")
    @test is_valid_db_default_sql("$(DBD_Q)--$(DBD_Q)")
    @test is_valid_db_default_sql("$(DBD_Q)/*$(DBD_Q)")
    @test is_valid_db_default_sql("$(DBD_Q)it$(DBD_Q)$(DBD_Q)s$(DBD_Q)")      # a doubled quote is an escape
    @test is_valid_db_default_sql("$(DBD_Q)($(DBD_Q)")                # an unbalanced paren inside a literal
    @test is_valid_db_default_sql("\"a;b\"")                  # …and inside a quoted identifier
end

# ─────────────────────────────────────────────────────────────────────────────
# The constructor contract: what is accepted, what is refused, and in what form it is stored
# ─────────────────────────────────────────────────────────────────────────────
@testset "db_default is validated and normalised at construction (#496)" begin
    # Accepted shapes.
    @test Models.DateTimeField(db_default = "CURRENT_TIMESTAMP").db_default == "CURRENT_TIMESTAMP"
    @test Models.UUIDField(db_default = (postgres = "gen_random_uuid()",)).db_default ==
          (postgres = "gen_random_uuid()",)
    @test Models.DateTimeField(db_default = (postgres = "now()", sqlite = "CURRENT_TIMESTAMP")).db_default ==
          (postgres = "now()", sqlite = "CURRENT_TIMESTAMP")
    # The per-engine opt-out: an explicit `nothing` means "no database default on this engine",
    # which is what lets a portable app carry a PostgreSQL-only expression without the models file
    # refusing to render on SQLite.
    @test Models.UUIDField(db_default = (postgres = "gen_random_uuid()", sqlite = nothing)).db_default ==
          (postgres = "gen_random_uuid()", sqlite = nothing)

    # KEY ORDER IS NORMALISED, and this is not cosmetic: `(a=1, b=2) != (b=2, a=1)` in Julia, so
    # without it two identical declarations would compare unequal in `_model_to_str_general`'s
    # struct diff (emitting a spurious kwarg) and in the column IR (planning a migration that
    # changes nothing).
    @test Models.DateTimeField(db_default = (sqlite = "CURRENT_TIMESTAMP", postgres = "now()")).db_default ==
          (postgres = "now()", sqlite = "CURRENT_TIMESTAMP")
    @test keys(Models.DateTimeField(db_default = (sqlite = "CURRENT_TIMESTAMP", postgres = "now()")).db_default) ==
          (:postgres, :sqlite)

    # Stored CANONICAL, on both shapes — the declared side must match what the live side stores or
    # the column never converges.
    @test Models.DateTimeField(db_default = "current_timestamp").db_default == "CURRENT_TIMESTAMP"
    @test Models.IntegerField(db_default = (sqlite = "(abs(random()) % 10)",)).db_default ==
          (sqlite = "abs(random()) % 10",)

    # #603: an `AbstractString` is accepted and normalised to `String`, so a `SubString` from a
    # generated models file or a web layer does not reach the DDL path as a view.
    sub = SubString("xxCURRENT_DATExx", 3, 14)
    @test sub == "CURRENT_DATE" && sub isa SubString
    @test Models.DateField(db_default = sub).db_default === "CURRENT_DATE"

    # Refusals, each naming the mistake it is for.
    #
    # A bare non-vocabulary string: PormG cannot know which engine it is valid on, and guessing is
    # the thing #496 refuses to do.
    @test_throws PormG.FieldValidationError Models.DateTimeField(db_default = "now()")
    # Both slots set. A departure from Django, for a PormG-specific reason: PormG's `default` is
    # BOTH rendered into the column definition and filled in Julia on the insert path, so a field
    # carrying both would have its `db_default` exercised by no PormG-written INSERT.
    @test_throws PormG.FieldValidationError Models.IntegerField(default = 5, db_default = "CURRENT_DATE")
    # An engine PormG does not have.
    @test_throws PormG.FieldValidationError Models.TextField(db_default = (mysql = "now()",))
    # Statement-breaking text, through the guard above.
    @test_throws PormG.FieldValidationError Models.TextField(db_default = (postgres = "1; DROP TABLE t",))
    # Degenerate NamedTuples: empty, and all-nothing. The second is the interesting one — it is
    # spelled "this column has no default anywhere", which is what `db_default = nothing` already
    # says, so accepting it would give one state two spellings.
    @test_throws PormG.FieldValidationError Models.TextField(db_default = NamedTuple())
    @test_throws PormG.FieldValidationError Models.TextField(db_default = (postgres = nothing,))
    # Wrong type entirely.
    @test_throws PormG.FieldValidationError Models.TextField(db_default = 5)
    @test_throws PormG.FieldValidationError Models.TextField(db_default = (postgres = 5,))

    # The two constructors that do NOT accept it warn and genuinely ignore, exactly as they already
    # do for `default` — never throw, because that would break the `Model_to_str` round trip for a
    # generated file that happens to carry the keyword.
    @test (@test_logs (:warn,) Models.IDField(db_default = "CURRENT_DATE")) isa Models.sIDField
    @test (@test_logs (:warn,) Models.PasswordField(db_default = "CURRENT_DATE")).db_default === nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# The slot itself, across every struct that has one
# The hazard this exists for: ten of the 23 structs declare `default::Union{String, Nothing}`, so a
# `db_default` placed beside it would TYPE-CHECK if the two positional arguments were ever swapped.
# The slot is appended last for that reason; this is the assertion that the appending actually
# happened everywhere, rather than the snapshot noticing it one constructor at a time.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the db_default slot is on every field that can have one, and only those (#496)" begin
    concrete = filter(t -> parentmodule(t) === PormG.Models, subtypes(PormG.PormGField))

    # Exactly two concrete field types have no slot, and each for a stated reason.
    without = filter(t -> !hasfield(t, :db_default), concrete)
    @test Set(nameof.(without)) == Set([:sIDField, :sManyToManyField])
    # `sIDField`: PostgreSQL rejects a column that is both `GENERATED … AS IDENTITY` and carries a
    # `DEFAULT`, so giving it the slot would make invalid DDL DECLARABLE — the one outcome the
    # design forbids. `sManyToManyField` describes a join table, not a column.
    @test !hasfield(Models.sIDField, :db_default)
    @test !hasfield(Models.sManyToManyField, :db_default)

    # Every other one has it, it is the LAST slot, and it defaults to `nothing`.
    for T in filter(t -> hasfield(t, :db_default), concrete)
        @test fieldnames(T)[end] === :db_default
        @test fieldtype(T, :db_default) == Models.DbDefault
    end

    # THE swap guard. Setting `db_default` must leave `default` clear on every type that takes the
    # keyword — a swapped positional argument would land the expression in `default` (where it
    # re-renders as a quoted literal: the #475 corruption) and type-check while doing it.
    ctors = [Models.CharField, Models.TextField, Models.EmailField, Models.URLField,
             Models.SlugField, Models.JSONField, Models.UUIDField, Models.DurationField,
             Models.ImageField, Models.IntegerField, Models.BigIntegerField,
             Models.PositiveIntegerField, Models.PositiveSmallIntegerField, Models.BooleanField,
             Models.DateField, Models.DateTimeField, Models.TimeField, Models.DecimalField,
             Models.FloatField, Models.BinaryField]
    for ctor in ctors
        f = ctor(db_default = "CURRENT_TIMESTAMP")
        @test f.db_default == "CURRENT_TIMESTAMP"
        @test f.default === nothing
    end
    # …and the two relational ones, which take a positional target.
    for ctor in (Models.ForeignKey, Models.OneToOneField)
        f = ctor("Driver"; db_default = "CURRENT_TIMESTAMP")
        @test f.db_default == "CURRENT_TIMESTAMP"
        @test f.default === nothing
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Rendering: verbatim on PostgreSQL, parenthesised on SQLite, and refused off-engine
# The SQLite parenthesisation is the ONE intentional engine divergence in #496 and it is forced by
# the grammar, not chosen: SQLite accepts a bare token only for its `literal-value` set — measured
# on 3.53.4, `DEFAULT abs(random())` is a syntax error while `DEFAULT (abs(random()))` is accepted.
# ─────────────────────────────────────────────────────────────────────────────
@testset "db_default renders per engine and refuses off-engine (#496)" begin
    render(f, conn) = Dialect.field_to_column("c", f, conn)

    # The vocabulary renders BARE on both engines — that is what makes it portable, and it is why
    # the vocabulary is defined by round-trip behaviour rather than by taste.
    @test occursin("DEFAULT CURRENT_TIMESTAMP",
                   render(Models.DateTimeField(db_default = "CURRENT_TIMESTAMP"), PG496))
    @test occursin("DEFAULT CURRENT_TIMESTAMP",
                   render(Models.DateTimeField(db_default = "CURRENT_TIMESTAMP"), SL496))
    # …and NOT parenthesised on SQLite, which would be a different (also valid) spelling that the
    # catalog would then report back differently, breaking convergence.
    @test !occursin("DEFAULT (CURRENT_TIMESTAMP)",
                    render(Models.DateTimeField(db_default = "CURRENT_TIMESTAMP"), SL496))

    # A pinned expression: verbatim on PostgreSQL…
    @test occursin("DEFAULT gen_random_uuid()",
                   render(Models.UUIDField(db_default = (postgres = "gen_random_uuid()",)), PG496))
    # …and parenthesised on SQLite.
    @test occursin("DEFAULT (abs(random()) % 10)",
                   render(Models.IntegerField(db_default = (sqlite = "abs(random()) % 10",)), SL496))

    # NEVER quoted. That is the whole difference from a `default=`, and the #475 corruption in one
    # assertion: a quoted `'now()'` stores five characters in every row instead of calling anything.
    sql = render(Models.DateTimeField(db_default = (postgres = "now()",)), PG496)
    @test occursin("DEFAULT now()", sql)
    @test !occursin("$(DBD_Q)now()$(DBD_Q)", sql)
    # …while a LITERAL default still is quoted, unchanged.
    @test occursin("DEFAULT $(DBD_Q)active$(DBD_Q)",
                   render(Models.CharField(max_length = 10, default = "active"), PG496))

    # The refusal. A models file may never emit DDL the target database will reject, so a pinned
    # expression raises rather than rendering or silently vanishing.
    @test_throws PormG.BackendCapabilityError render(
        Models.UUIDField(db_default = (postgres = "gen_random_uuid()",)), SL496)
    @test_throws PormG.BackendCapabilityError render(
        Models.IntegerField(db_default = (sqlite = "abs(random()) % 10",)), PG496)
    # The message has to be actionable: it names both engines and both remedies, because the user
    # reading it is holding a models file that works on one database and not the other.
    err = try
        render(Models.UUIDField(db_default = (postgres = "gen_random_uuid()",)), SL496)
        nothing
    catch e
        e
    end
    @test err isa PormG.BackendCapabilityError
    msg = PormG.error_message(err)
    @test occursin("postgres", msg) && occursin("sqlite", msg)
    @test occursin("gen_random_uuid()", msg)
    @test occursin("nothing", msg)                      # the opt-out is offered
    @test occursin("CURRENT_TIMESTAMP", msg)            # …and so is the portable alternative

    # The per-engine opt-out renders NOTHING on the opted-out engine, and does not raise — that is
    # the difference between "this column has no default here" and "I forgot this engine".
    both = Models.UUIDField(db_default = (postgres = "gen_random_uuid()", sqlite = nothing))
    @test occursin("DEFAULT gen_random_uuid()", render(both, PG496))
    @test !occursin("DEFAULT", render(both, SL496))
end

# ─────────────────────────────────────────────────────────────────────────────
# The compiler and the diff — convergence, and the one deliberate asymmetry
# This is the testset that guards the repo's most-repeated bug class. A column compiled from a
# declaration must equal the same column read back from the catalog; if it does not,
# `makemigrations` proposes DDL on every run forever (#325 → #408 → #409 → #417 → #437 → #498 →
# #503, one bug shape seen seven times).
# ─────────────────────────────────────────────────────────────────────────────
@testset "db_default compiles into the IR and diffs correctly (#496)" begin
    spec(f, conn) = Migrations.column_spec(f, conn; name = "c")

    # The declared side produces an `ExpressionDefault`, canonical.
    @test spec(Models.DateTimeField(db_default = "current_timestamp"), PG496).default ==
          ExpressionDefault("CURRENT_TIMESTAMP")
    # On SQLite the RENDERED text carries the required parens but the STORED text does not — the
    # compiler canonicalises, so the two engines describe one expression the same way.
    @test spec(Models.IntegerField(db_default = (sqlite = "abs(random()) % 10",)), SL496).default ==
          ExpressionDefault("abs(random()) % 10")

    # A literal is untouched by any of this.
    @test spec(Models.IntegerField(default = 5), PG496).default == LiteralDefault(5)
    @test spec(Models.IntegerField(), PG496).default == NoDefault()

    # Same declaration, same spec — including when the user typed it differently. This is
    # convergence in its smallest form.
    @test spec(Models.DateTimeField(db_default = "CURRENT_TIMESTAMP"), PG496) ==
          spec(Models.DateTimeField(db_default = "current_timestamp"), PG496)

    # The delta vocabulary. `db_default` folds into the EXISTING `:default` slot rather than adding
    # one, because `ColumnDefault` is a sum type — which is why `alter_field` needed no new branch
    # and the golden-plan corpus needed no new case.
    a = spec(Models.DateTimeField(db_default = "CURRENT_TIMESTAMP"), PG496)
    b = spec(Models.DateTimeField(db_default = (postgres = "now()",)), PG496)
    @test column_delta(b, a) == [:default]
    @test column_delta(a, a) == Symbol[]
    # An expression against a literal is a difference — #475's quoting distinction survives.
    @test column_delta(a, spec(Models.DateTimeField(), PG496)) == [:default]

    # THE ASYMMETRY, and the reason it exists. A live expression default the model does not declare
    # is NOT a difference, so `makemigrations` never proposes `DROP DEFAULT` against a database
    # default PormG was not asked to manage. Before #496 the reader dropped the expression and the
    # two sides agreed by accident; `docs/src/schema_conventions.md` promised that behaviour in as
    # many words, and this arm is what keeps the promise now that the reader CAN see it. Without it,
    # every existing app would get an unprompted `DROP DEFAULT` on its first run after upgrading —
    # unprompted because `DROP DEFAULT` is not classified destructive on PostgreSQL.
    declared_none = spec(Models.DateTimeField(), PG496)
    live_expr = spec(Models.DateTimeField(db_default = (postgres = "now()",)), PG496)
    @test column_delta(declared_none, live_expr) == Symbol[]
    # …and it is ONE-WAY. Declaring one where the database has none is still planned, or there
    # would be no way to add a db_default at all.
    @test column_delta(live_expr, declared_none) == [:default]

    # `==` on a spec stays SYMMETRIC despite that, and `hash` stays consistent with it. The
    # comparator table is directional by construction (`new_spec, old_spec`); `==` asks it both
    # ways, so the asymmetric pair compares unequal rather than making `a == b` depend on argument
    # order and breaking the `a == b ⇒ hash(a) == hash(b)` contract this IR maintains.
    @test (declared_none == live_expr) === (live_expr == declared_none) === false
    for x in (declared_none, live_expr, a, b), y in (declared_none, live_expr, a, b)
        @test !(x == y) || hash(x) == hash(y)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# The refusal must not be laundered by the fail-safe wrapper
# `_spec_or_degraded` catches everything but interrupted/corrupted program state and degrades to a
# `CUnsupported` spec, which is right for an UNFORESEEN failure — its own comment says so. A pin
# mismatch is foreseen and has exactly one remedy, so degrading it would turn a precise, actionable
# refusal into a column `makemigrations` then plans DDL for. Found while wiring the compiler.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a pinned-to-the-other-engine db_default propagates through the fail-safe (#496)" begin
    f = Models.UUIDField(db_default = (postgres = "gen_random_uuid()",))
    @test_throws PormG.BackendCapabilityError Migrations._spec_or_degraded(f, SL496, "<m>"; name = "c")
    # The control: an ordinary uncompilable column still degrades rather than raising, so the
    # rethrow above is scoped to the new case and has not disabled the #69 fail-safe.
    degraded = Migrations._degraded_spec(Models.IntegerField(), PG496, "<m>"; name = "c")
    @test degraded.type isa PormG.Migrations.CUnsupported
end

# ─────────────────────────────────────────────────────────────────────────────
# The Model_to_str round trip
# `inspectdb` writes a models file and PormG reads it back; a `db_default` that did not survive that
# cycle would be a silently different model on the next load — the #501 shape. The NamedTuple form
# relies on Julia's own `show` to escape the strings inside it, which is why the adversarial
# characters are the point of this testset rather than decoration.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a db_default survives Model_to_str and reloads identically (#496)" begin
    cases = [
        ("portable",  Models.DateTimeField(db_default = "CURRENT_TIMESTAMP")),
        ("pinned",    Models.TextField(db_default = (postgres = "concat($(DBD_Q)a$(DBD_Q)::text, $(DBD_Q)b$(DBD_Q)::text)",))),
        ("both",      Models.DateTimeField(db_default = (postgres = "now()", sqlite = "CURRENT_TIMESTAMP"))),
        ("opt-out",   Models.UUIDField(db_default = (postgres = "gen_random_uuid()", sqlite = nothing))),
        # The adversarial one: a double quote closes the literal early, a `$` makes the generated
        # source INTERPOLATE rather than fail, and a backslash escapes whatever follows. All three
        # have shipped as bugs in this exact seam before (#317, #602).
        ("hostile",   Models.TextField(db_default = (postgres = "x || \$\$y\$\$ || \"Q\" || $(DBD_Q)a$(DBD_Q) || 'z\\'",))),
    ]

    for (label, field) in cases
        model = Models.Model("lap_note", id = Models.IDField(), c = field)
        src = Models.Model_to_str(model)
        @test occursin("db_default=", src)
        # …and never as a `default=`, which is the corrupting spelling. `(?<!_)` rather than
        # `[^_]`: a negative lookbehind matches at the start of the kwarg list too, where a
        # character class has nothing to consume — so `CharField(default="x")`, with `default=`
        # as the FIRST kwarg, would have slipped past the class form. Found in review.
        @test !occursin(r"c = Models\.\w+\([^)]*(?<!_)default=", src)

        # Reload through the same seam a generated file uses: parse the emitted kwargs back.
        m = match(r"c = (Models\.[A-Za-z]+\(.*?\))\)\z"s, src)
        expr = m === nothing ? match(r"c = (Models\.[A-Za-z]+\(.*?\))[,\)]"s, src).captures[1] :
                               m.captures[1]
        back = eval(Meta.parse(replace(expr, "Models." => "PormG.Models.")))
        @test back.db_default == field.db_default
        @test typeof(back) === typeof(field)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# The planner guard: a db_default column needs no temporary default
# A NOT NULL temporal column added to a populated table normally gets a temporary default so the
# backfill has a value; the cleanup step then DROPS it, forcing a `[:default]` delta whose new side
# is `NoDefault`. A column that computes its own default must be excluded, or that cleanup would
# drop the real expression default it had just rendered.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a db_default column is not given a temporary default (#496)" begin
    settings = PormG.Configuration.Settings()

    # The control first, so a silent change to the temporary-default machinery cannot make the
    # assertion below vacuous: a NOT NULL temporal column with neither default DOES get one.
    @test Migrations._get_temporary_default_value(
        Models.DateTimeField(null = false), settings) !== nothing

    for f in (Models.DateTimeField(null = false, db_default = "CURRENT_TIMESTAMP"),
              Models.DateTimeField(null = false, db_default = (postgres = "now()",)),
              Models.DateField(null = false, db_default = "CURRENT_DATE"))
        @test Migrations._get_temporary_default_value(f, settings) === nothing
    end

    # …and the SQLite inline-FK predicate, for the same underlying reason: SQLite refuses
    # `ADD COLUMN` with a non-constant default on a populated table (measured: `Cannot add a column
    # with non-constant default`), so such a column has to arrive through the table rebuild, which
    # is exactly where `false` sends it.
    fk = Models.ForeignKey("Driver"; null = true, db_default = "CURRENT_TIMESTAMP")
    @test !Dialect.sqlite_add_column_can_inline_fk(fk, nothing)
    plain = Models.ForeignKey("Driver"; null = true)
    @test Dialect.sqlite_add_column_can_inline_fk(plain, nothing)
end

# ─────────────────────────────────────────────────────────────────────────────
# check() reports only the columns the importer can actually describe
# The finding's ADVICE is "declare it as `db_default=`", so reporting a column whose arm has no such
# slot is advice that cannot be followed: `IDField` answers it with
# "Unexpected parameter … will be ignored" and the user's edit is a no-op.
#
# Found in review, and the gap was wider than the original skip. `_integer_key_arm` covered only an
# INTEGER key, but EVERY key on the fall-through arm compiles to `IDField` — a `BLOB` key, a `REAL`
# one — with the single exception of a lengthless TEXT key on SQLite, which becomes a `UUIDField`
# and does carry it. `_arm_carries_db_default` states that once, and `check` asks it rather than
# mirroring it, which is the same anti-drift rule `_key_arm` itself exists for.
# ─────────────────────────────────────────────────────────────────────────────
@testset "check() skips the key arms that cannot carry a db_default (#496)" begin
    carries = Migrations._arm_carries_db_default

    # The fall-through key arm compiles to `IDField` on every type but one, so it carries nothing.
    for ctype in (Migrations.CInt64(), Migrations.CBytes(), Migrations.CFloat64())
        @test !carries(:id_pk, ctype, PG496)
        @test !carries(:id_pk, ctype, SL496)
    end
    # …and `IDField` really does refuse the keyword, which is what makes reporting it useless.
    @test !hasfield(Models.sIDField, :db_default)

    # THE exception: a lengthless TEXT key on SQLite is `UUIDField(primary_key = true)`, the one
    # lengthless textual key PormG can declare — and it has the slot.
    @test carries(:id_pk, Migrations.CText(), SL496)
    # On PostgreSQL the same shape still flattens to `IDField` (the documented engine divergence in
    # `_inspectdb_field`), so it does NOT carry.
    @test !carries(:id_pk, Migrations.CText(), PG496)

    # Every other arm carries it on both engines.
    for arm in (:uuid_pk, :reference, :varchar_pk, :generic), conn in (PG496, SL496)
        @test carries(arm, Migrations.CText(), conn)
    end

    # CLOSING THE LOOP, and this is the assertion that makes the rest mean something. Everything
    # above compares the predicate to a literal, so it would still pass if someone re-pointed a
    # `:id_pk` branch at a slot-bearing field and the predicate silently became wrong. This drives
    # `field_from_spec` for real and asserts the field it builds agrees. Flagged in review, where
    # the testset was "asserting the predicate against itself".
    for (ctype, conn) in ((Migrations.CInt64(), PG496), (Migrations.CInt64(), SL496),
                          (Migrations.CBytes(), SL496), (Migrations.CFloat64(), SL496),
                          (Migrations.CText(), SL496), (Migrations.CText(), PG496),
                          (Migrations.CUUID(), PG496))
        spec = ColumnSpec("k", ctype, false, true, true, NoDefault(), nothing,
                          Migrations.CheckKind[], nothing, "raw")
        tbl = Migrations.LiveTable("t", Migrations.OrderedDict("k" => spec),
                                   Dict{String, Union{String, Nothing}}(),
                                   Pair{String, Vector{String}}[])
        f = Logging.with_logger(Logging.NullLogger()) do
            Migrations.field_from_spec(spec, tbl, conn)
        end
        arm = Migrations._inspectdb_key_arm(spec)
        @test hasfield(typeof(f), :db_default) == carries(arm, ctype, conn)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# SQLite's ADD COLUMN cannot carry the default, so the statement defers it
# Measured on SQLite 3.53.4: `ALTER TABLE … ADD COLUMN … DEFAULT CURRENT_TIMESTAMP` on a table that
# has ROWS fails with `Cannot add a column with non-constant default` — for the portable vocabulary
# just as much as for a parenthesised expression. (An EMPTY table accepts both, which is why this
# was invisible until a populated fixture was tried.) The planner cannot know which it faces and
# must not query to find out, so the ADD COLUMN drops the default AND the NOT NULL, a backfill
# UPDATE fills the existing rows, and the rebuild that is already queued restores both.
#
# That sequence is also what keeps the engines equal: PostgreSQL's `ADD COLUMN … DEFAULT expr`
# backfills existing rows by itself, so without the UPDATE the same migration would leave SQLite
# rows NULL where PostgreSQL rows have a value.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite defers a db_default on ADD COLUMN and backfills (#496)" begin
    f = Models.DateTimeField(null = false, db_default = "CURRENT_TIMESTAMP")

    # The deferred rendering: no DEFAULT, and NULL rather than NOT NULL (SQLite refuses
    # `ADD COLUMN … NOT NULL` with no default to fill the existing rows).
    added = Dialect.add_field(SL496, "lap", "c", f)
    @test occursin("ADD COLUMN", added)
    @test !occursin("DEFAULT", added)
    @test occursin("NULL", added) && !occursin("NOT NULL", added)

    # …while the SAME field rendered for a CREATE TABLE — the flag off — keeps both. If this
    # regressed, the deferral would be silently permanent and the column would lose its default.
    created = Dialect.field_to_column("c", f, SL496)
    @test occursin("DEFAULT CURRENT_TIMESTAMP", created)
    @test occursin("NOT NULL", created)

    # PostgreSQL is NOT deferred: it accepts the default on ADD COLUMN and backfills by itself.
    @test occursin("DEFAULT CURRENT_TIMESTAMP", Dialect.add_field(PG496, "lap", "c", f))

    # A field with no `db_default` is untouched by any of this — the deferral must not leak into
    # the ordinary ADD COLUMN path.
    lit = Models.IntegerField(null = true, default = 7)
    @test occursin("DEFAULT 7", Dialect.add_field(SL496, "lap", "c", lit))
end

# ─────────────────────────────────────────────────────────────────────────────
# …and the backfill that makes the deferral safe, at the PLAN level
# The rendering assertions above cannot see this half, and it is the half that fails SILENTLY: a
# wrong column name leaves every existing row NULL after a migration that reports success, and a
# backfill queued AFTER the rebuild lets the rebuild copy NULLs into a NOT NULL column. Flagged in
# review as untested — `Backfill db_default` had one hit in `src/` and none in `test/`.
#
# A real temp SQLite database rather than a mock: the rebuild path queries the connection for
# secondary indexes, so a bare marker struct cannot reach it. Still hermetic — its own file, dropped
# with the temp dir.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the SQLite db_default backfill is planned, named and ordered (#496)" begin
    mktempdir() do dir
        pool = SQLiteConnectionPool(joinpath(dir, "backfill.sqlite"); pool_size = 1)
        try
            fetch(pool, """CREATE TABLE "lap" ("id" INTEGER PRIMARY KEY, "note" TEXT)""")
            fetch(pool, """INSERT INTO "lap" ("id", "note") VALUES (1, 'Senna')""")

            declared = Models.Model("lap",
                id   = Models.IDField(),
                note = Models.TextField(null = true),
                # `db_column` deliberately differs from the field name: the UPDATE must name the
                # PHYSICAL column (`Models.field_db_column`), and a test whose two names coincide
                # could not tell the difference.
                c    = Models.DateTimeField(null = false, db_default = "CURRENT_TIMESTAMP",
                                            db_column = "created_at"))

            settings = PormG.Configuration.Settings()
            settings.change_db = true
            live = Migrations.convertSQLToModel(pool, "lap")
            current = Dict{Symbol, Dict{Symbol, Union{Bool, PormG.PormGModel}}}(
              :lap => Dict{Symbol, Union{Bool, PormG.PormGModel}}(:model => declared, :exist => false))
            plan = Migrations.get_migration_plan(PormG.PormGModel[live], current, pool, settings)
            steps = plan[:lap]
            keys_in_order = collect(keys(steps))

            add_i  = findfirst(k -> startswith(k, "Add field:"), keys_in_order)
            fill_i = findfirst(k -> startswith(k, "Backfill db_default:"), keys_in_order)
            alter_i = findfirst(k -> startswith(k, "Alter table:"), keys_in_order)
            @test add_i !== nothing && fill_i !== nothing && alter_i !== nothing

            # ORDER IS THE POINT. Backfill after the column exists, and before the rebuild copies
            # rows into a NOT NULL column. The rebuild is relocated to the END on every
            # registration, so this ordering has to survive that.
            @test add_i < fill_i < alter_i

            fill_sql = steps[keys_in_order[fill_i]]
            @test occursin("UPDATE", fill_sql)
            @test occursin("created_at", fill_sql)          # the PHYSICAL column…
            @test !occursin("\"c\"", fill_sql)              # …not the field name
            @test occursin("CURRENT_TIMESTAMP", fill_sql)
            # `IS NULL`-guarded, because a plan is a list of statements that may be re-run against a
            # partially-migrated database; an unconditional SET would overwrite real values.
            @test occursin("IS NULL", fill_sql)

            # The ADD COLUMN it is compensating for carries neither the default nor NOT NULL.
            add_sql = steps[keys_in_order[add_i]]
            @test !occursin("DEFAULT", add_sql)
            @test !occursin("NOT NULL", add_sql)
            # …while the rebuild restores both.
            @test occursin("DEFAULT CURRENT_TIMESTAMP", steps[keys_in_order[alter_i]])
            @test occursin("NOT NULL", steps[keys_in_order[alter_i]])

            # THE CONTROL: a literal default needs none of this, so no backfill step is planned.
            plain = Models.Model("lap",
                id   = Models.IDField(),
                note = Models.TextField(null = true),
                c    = Models.IntegerField(null = true, default = 7))
            current2 = Dict{Symbol, Dict{Symbol, Union{Bool, PormG.PormGModel}}}(
              :lap => Dict{Symbol, Union{Bool, PormG.PormGModel}}(:model => plain, :exist => false))
            plan2 = Migrations.get_migration_plan(PormG.PormGModel[live], current2, pool, settings)
            @test !any(startswith(k, "Backfill db_default:") for k in keys(plan2[:lap]))
        finally
            close_pool!(pool)
        end
    end
end
