"""
Unit coverage for reserved-word column names — the `db_column` spelling (#317).

A model can still expose a SQL column whose name collides with a Julia keyword (`end`,
`function`) or is otherwise not a legal Julia keyword-argument name. What changed in #317
is **how you say it**: the field carries a legal Julia identity and pins the physical column
with `db_column` (#50).

    end_ = Models.CharField(db_column = "end")     # field `end_`  → column "end"

The old spelling was a single leading underscore, which `format_fild_name` stripped
(`_end` → column `end`). That hatch is retired: it encoded two different things in one
string, it cost #306 and a `Model_to_str` output that would not reload, and it forced a
grammar restriction on everyone. A leading underscore in a **declared** field name now
raises `ModelDefinitionError` naming `db_column`.

Note `var"end" = CharField()` — Julia's own non-standard-identifier syntax — also works and
declares the field `end` directly. It is supported but not taught, because it does **not**
escape a model-OPTION collision: `var"db_table"` still parses to the kwarg `:db_table` and
is peeled as the option. `db_column` is the one spelling that covers every case.

All assertions render via a mock PostgreSQL connection (no live database required).
"""

using Test
using PormG
using PormG.Models: Model, CharField, IDField, format_fild_name, add_field!
using PormG.QueryBuilder: inspect_query

# Mechanics-only fixture: the reserved words `end` / `function` are declared under legal Julia
# identities and pinned to their real columns with `db_column`. `id` needs nothing special — it
# was never a Julia reserved word, only an entry in PormG's own over-broad list (#317).
ReservedWordModel = Model("reserved_word_scratch",
  id        = IDField(),
  function_ = CharField(null=true, db_column="function"),
  end_      = CharField(null=true, db_column="end"),
  nome      = CharField(null=true),
)
ReservedWordModel.connect_key = "default"

# Dedicated mock connection — uniquely named so it never clashes with other unit files'
# mock structs when runtests.jl includes them into the same module.
struct MockPostgresReservedFields <: PormG.PormGPostgres end
PormG.config["default"] = PormG.Configuration.Settings(
  connections = MockPostgresReservedFields(),
  change_data = true,
)

@testset "Reserved-word columns via db_column" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # format_fild_name is now a pure pass-through VALIDATOR. It rewrites nothing, so a
  # reference to a field key resolves to that key exactly — which is what lets a
  # Dict-built (introspected) model keyed `_id` be named by `pk_field`, a constraint,
  # or a row lookup.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "format_fild_name no longer rewrites" begin
    @test format_fild_name("_id")       == "_id"
    @test format_fild_name("_end")      == "_end"
    @test format_fild_name("_function") == "_function"
    # Already-bare names still pass through unchanged.
    @test format_fild_name("nome")      == "nome"
    @test format_fild_name("id")        == "id"
    # Case is PRESERVED, not folded (#57): declare `driverId`, keep `driverId`.
    @test format_fild_name("driverId")  == "driverId"
    @test format_fild_name("_DriverId") == "_DriverId"
    # `__` and `@` are still rejected — those are the lookup separator and the operator
    # marker, so such a field would be unqueryable. That restriction never came from the
    # hatch, so `__id` still throws; what changed is that it is no longer reached by first
    # stripping `__id` down to `_id`.
    @test_throws PormG.ModelDefinitionError format_fild_name("a__b")
    @test_throws PormG.ModelDefinitionError format_fild_name("a@b")
    @test_throws PormG.ModelDefinitionError format_fild_name("__id")
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The DECLARATION paths reject a leading underscore and name the replacement. This is
  # what turns a silent schema change (`_id` quietly becoming the column `_id`) into a
  # load-time error.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "declaring a leading-underscore field is rejected" begin
    err = try
      Model("rw317_scratch", _id = IDField())
      nothing
    catch e
      e
    end
    @test err isa PormG.ModelDefinitionError
    @test occursin("_id", err.msg)
    @test occursin("db_column", err.msg)
    @test occursin("rw317_scratch", err.msg)          # says WHICH model
    @test occursin("db_column = \"id\"", err.msg)     # the column they probably meant
    @test occursin("db_column = \"_id\"", err.msg)    # …and the one they might have meant

    # The no-positional-name form funnels through the same constructor.
    @test_throws PormG.ModelDefinitionError Model(_end = CharField())

    # add_field! is the other path that takes a user-written name — both arities.
    target = Model("rw317_addfield_scratch", id = IDField())
    @test_throws PormG.ModelDefinitionError add_field!(target, :_end, CharField())
    @test_throws PormG.ModelDefinitionError add_field!(target, "_end", CharField())
    # …and a legal name still works, so the guard is not blanket-rejecting.
    add_field!(target, :end_, CharField(db_column="end"))
    @test haskey(target.fields, "end_")

    # A reserved word suggested back must itself be legal to type: `_end` suggests `end_`,
    # not `end` (which is a Julia syntax error as a kwarg).
    err_end = try; Model("rw317_hint_scratch", _end = CharField()); nothing; catch e; e; end
    @test occursin("end_ = Models.CharField(db_column = \"end\")", err_end.msg)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The surviving user capability, end to end. These are the direct successors of the
  # assertions the underscore fixture used to make: the SAME SQL, a different declaration.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "db_column renders the reserved-word column" begin
    q = ReservedWordModel.objects
    q.filter("id" => 7)
    insp = inspect_query(q)
    @test occursin("\"Tb\".\"id\" = \$1", insp[:sql_text])
    @test insp[:parameters] == [7]
  end

  @testset "values projects reserved-word columns with an alias" begin
    q = ReservedWordModel.objects
    q.filter("function_" => "x")
    q.values("the_end" => "end_", "function_", "nome")
    insp = inspect_query(q)
    # Projection renders the PHYSICAL column; the alias is the caller's, or the field name.
    @test occursin("\"Tb\".\"end\" as \"the_end\"", insp[:sql_text])
    @test occursin("\"Tb\".\"function\" as \"function_\"", insp[:sql_text])
    @test occursin("\"Tb\".\"function\" = \$1", insp[:sql_text])
    @test insp[:parameters] == ["x"]
  end

  @testset "DDL emits the physical reserved words, not the field identities" begin
    ddl = PormG.Dialect.create_table(MockPostgresReservedFields(), ReservedWordModel)
    @test occursin("\"end\"", ddl)
    @test occursin("\"function\"", ddl)
    @test !occursin("\"end_\"", ddl)
    @test !occursin("\"function_\"", ddl)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Julia's own escape works for a plain field name, and demonstrably does NOT work for a
  # model-option name — which is precisely why `db_column` is the taught spelling.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "var\"...\" declares the field directly but cannot escape a model option" begin
    m = Model("rw317_var_scratch", id = IDField(), var"end" = CharField(null=true))
    @test haskey(m.fields, "end")
    @test PormG.Models.field_db_column(m.fields["end"], "end") == "end"

    # `var"db_table"` parses to the kwarg name `:db_table`, which `Model` peels as the OPTION
    # before the fields slurp — so it never becomes a column, whatever the spelling. Assert on the
    # CAUSE: a bare `Exception` would also pass for a typo or an UndefVarError.
    opt_err = try
      Model("rw317_opt_scratch", id = IDField(), var"db_table" = CharField()); nothing
    catch e; e end
    @test opt_err isa PormG.ModelDefinitionError
    @test occursin("'db_table' option", opt_err.msg)
    @test occursin("must be a String", opt_err.msg)
    # The spelling that actually declares that column:
    opt = Model("rw317_opt2_scratch", id = IDField(), table_kind = CharField(db_column="db_table"))
    @test PormG.Models.field_db_column(opt.fields["table_kind"], "table_kind") == "db_table"
    @test opt.db_table === nothing   # the OPTION is untouched
    @test occursin("\"db_table\"", PormG.Dialect.create_table(MockPostgresReservedFields(), opt))
  end

end
