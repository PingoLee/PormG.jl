"""
Unit coverage for reserved-word / leading-underscore field names.

PormG lets a model expose a SQL column whose name collides with a Julia reserved word
(e.g. `end`, `function`) — or simply with `id` — by declaring the field with a single
leading underscore (`_end`, `_function`, `_id`). `format_fild_name` strips that one
leading underscore (case is preserved — see #57), so the field is referenced everywhere —
model definition, `filter`, `values` — by its *stripped* name; the underscored form never
reaches SQL.

Downstream consumers depend on this contract: LinkSUS declares `_id` on every model and
`_function` on its `b1_proc`/`b2_proc` models, and queries them as `"id"` / `"function"`
(e.g. `revisa_row`'s `.filter("id" => row)`). This test pins the rendered SQL so a future
QueryBuilder/Models change can't silently break it.

All assertions render via a mock PostgreSQL connection (no live database required).
"""

using Test
using PormG
using PormG.Models: Model, CharField, IDField, format_fild_name
using PormG.QueryBuilder: inspect_query

# Mechanics-only fixture: `id` and the reserved words `end` / `function` are declared with
# a leading underscore (valid Julia kwargs) and must register as the stripped SQL columns
# "id" / "end" / "function".
ReservedWordModel = Model("reserved_word_scratch",
  _id       = IDField(),
  _function = CharField(null=true),
  _end      = CharField(null=true),
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

@testset "Reserved-word / underscore field names" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # format_fild_name: normalization — strips ONE leading underscore, PRESERVES case.
  # `_id`/`_end`/`_function` resolve to the bare SQL identifiers `id`/`end`/`function`.
  # This is the single function every column name and query key flows through.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "format_fild_name strips one leading underscore" begin
    @test format_fild_name("_id")       == "id"
    @test format_fild_name("_end")      == "end"
    @test format_fild_name("_function") == "function"
    @test format_fild_name("_index")    == "index"
    # Already-bare names pass through unchanged (idempotent on a stripped name).
    @test format_fild_name("nome")      == "nome"
    @test format_fild_name("id")        == "id"
    # Case is PRESERVED, not folded (#57): declare `driverId`, keep `driverId`.
    @test format_fild_name("driverId")  == "driverId"
    @test format_fild_name("_DriverId") == "DriverId"
    # Only ONE leading underscore is stripped; a residual leading `_` is rejected so a
    # double leading underscore can never be mistaken for a stripped name.
    @test_throws PormG.ModelDefinitionError format_fild_name("__id")
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # filter() on the stripped name of an underscore-declared field renders the bare
  # column in WHERE (`_id` -> "id"), proving the model registered the field under its
  # stripped name. Mirrors LinkSUS `revisa_row`'s `.filter("id" => row)`.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "filter resolves stripped reserved name" begin
    q = ReservedWordModel.objects
    q.filter("id" => 7)
    insp = inspect_query(q)
    @test occursin("\"Tb\".\"id\" = \$1", insp[:sql_text])
    @test insp[:parameters] == [7]
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # values() projects the stripped reserved-word columns (`end`, `function`) as
  # double-quoted SQL identifiers, and an alias maps one back to a safe output name.
  # Confirms reserved words survive selection rather than being dropped or mangled.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "values projects stripped reserved names with alias" begin
    q = ReservedWordModel.objects
    q.filter("function" => "x")
    q.values("the_end" => "end", "function", "nome")
    insp = inspect_query(q)
    @test occursin("\"Tb\".\"end\" as \"the_end\"", insp[:sql_text])
    @test occursin("\"Tb\".\"function\" as \"function\"", insp[:sql_text])
    @test occursin("\"Tb\".\"function\" = \$1", insp[:sql_text])
    @test insp[:parameters] == ["x"]
  end

end
