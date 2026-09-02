# julia --project=. test/unit/test_reverse_join_mixed_case_binding.jl
#
# #343 — a reverse relation must reach a model whose Julia BINDING carries internal capitals.
#
# Until #343 every reverse consumer recovered the child's binding by respelling its logical name:
# `Symbol(uppercasefirst(string(related_objects[key][3])))`. That slot is written through
# `get_model_name`, which lowercases unconditionally, so the reconstruction could only ever produce
# `Xxxxx` — first letter capital, everything else lower. And it is not a matter of a smarter fold:
# since #300 a positional model name is REJECTED unless already lowercase, so the capitals were
# never stored anywhere to recover.
#
# The result was that any binding like `Dim_CNES`, `CustomUser` or `Cust_adminHOD` was unreachable
# in reverse and raised `UndefVarError: Dim_cnes` — ten of 668 models across the consuming apps,
# including a central dimension table. Forward FKs were unaffected (`.to` carries the class name),
# which is why it went unnoticed: every binding in `test/integration/db_*/models.jl` is spelled
# exactly `uppercasefirst(lowercase(name))`, so no existing fixture could reproduce it.
#
# The fixture below is the shape the Django importer actually emits — a lowercase positional name
# (#300-legal) under a mixed-case binding — pinned by test_import_django_models.jl's
# `Dim_CNES = Models.Model("dim_cnes"` assertion. Each testset targets one of the four sites that
# used to reconstruct: build_joins.jl first-hop, build_joins.jl multi-hop loop, ctes.jl
# `_resolve_join_target_model`, and deletion.jl `find_related_objects!`.
#
# Everything here renders against a mock backend — no database. The pre-#343 failure was an
# `UndefVarError` at query-BUILD time, so `inspect_query` traverses the identical code path a
# `list()` would; there is no row-level behavior to observe because no SQL was produced at all.

using Test
using PormG
using PormG.Models
using PormG.QueryBuilder: inspect_query

# Dedicated mock + config key — uniquely named so they never clash with other unit files' mock
# structs when runtests.jl includes them all into the same module.
struct MockSQLiteMixedCaseBinding <: PormG.PormGSQLite end
PormG.backend_sqlite_version(::MockSQLiteMixedCaseBinding) = 3045000

PormG.config["mixed_case_binding_mock"] = PormG.Configuration.Settings(
  connections = MockSQLiteMixedCaseBinding(),
  change_data = true,
  db_def_folder = "mixed_case_binding_mock"
)

module MixedCaseBindingModels
import PormG
import PormG.Models

# Plain binding — the parent every reverse hop starts from.
Dim_Unidade = Models.Model("dim_unidade",
  id = Models.IDField(),
  nome = Models.CharField(),
)

# THE regression subject. `uppercasefirst(lowercase("dim_cnes"))` is "Dim_cnes", which is NOT this
# binding — so before #343 every reverse consumer threw `UndefVarError: Dim_cnes` here. No explicit
# related_name, so this exercises the implicit-accessor producer branch.
Dim_CNES = Models.Model("dim_cnes",
  id = Models.IDField(),
  nome = Models.CharField(),
  unidade = Models.ForeignKey(Dim_Unidade, pk_field = "id", on_delete = "CASCADE"),
)

# Second mixed-case binding, reached only as the SECOND hop of a chained reverse path, and declared
# with an explicit related_name so the other producer branch is covered too.
CustomUser = Models.Model("customuser",
  id = Models.IDField(),
  login = Models.CharField(),
  cnes = Models.ForeignKey(Dim_CNES, pk_field = "id", on_delete = "CASCADE", related_name = "usuarios"),
)

PormG.Models.set_models(@__MODULE__, "mixed_case_binding_mock")
end

const MC = MixedCaseBindingModels

# ─────────────────────────────────────────────────────────────────────────────
# The producer: set_models must RECORD the binding, because nothing can recover it later.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Mixed-case binding - related_objects records the binding (#343)" begin
    # Implicit accessor: the key is the child's logical name, lowercase.
    rel = MC.Dim_Unidade.related_objects["dim_cnes"]
    @test rel isa Models.ReverseRelation
    @test rel.fk_field == :unidade          # FK column on the CHILD
    @test rel.target_pk == :id              # column on the PARENT that the FK references
    @test rel.model_name == :dim_cnes       # logical name — lowercase, and lossy by construction

    # The two slots #343 added. `binding` is what respelling could never produce, and
    # `model_resolved` is what makes the lookup unnecessary in the first place.
    @test rel.binding === :Dim_CNES
    @test rel.model_resolved === MC.Dim_CNES

    # The precise loss: the old reconstruction applied to the stored name yields a binding that is
    # not defined in the module. This is the bug, expressed as an assertion.
    @test Symbol(uppercasefirst(String(rel.model_name))) === :Dim_cnes
    @test !isdefined(MC, :Dim_cnes)
    @test isdefined(MC, rel.binding)

    # Explicit related_name arm of the producer, second mixed-case binding.
    rel2 = MC.Dim_CNES.related_objects["usuarios"]
    @test rel2 isa Models.ReverseRelation
    @test rel2.fk_field == :cnes
    @test rel2.binding === :CustomUser
    @test rel2.model_resolved === MC.CustomUser
    @test !isdefined(MC, :Customuser)
end

# ─────────────────────────────────────────────────────────────────────────────
# build_joins.jl — first hop. Pre-#343 this threw UndefVarError before rendering anything.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Mixed-case binding - reverse join renders (build_joins first hop)" begin
    q = MC.Dim_Unidade.objects
    q.values("nome", "dim_cnes__nome")

    sql = inspect_query(q)[:sql_text]

    @test contains(sql, "JOIN")
    @test contains(sql, "dim_cnes")

    # Pin the ON clause LITERALLY, both sides. A `contains(sql, "dim_cnes")` check passes even if
    # key_a and key_b are transposed, and this diff rewrote exactly those two assignments — so the
    # cheap assertion cannot see the one mistake the change was most able to make.
    # key_a is the PARENT's referenced column (dim_unidade.id); key_b is the CHILD's FK column
    # (dim_cnes.unidade). Transposing them yields ON "Tb"."unidade" = "Tb_1"."id", which is wrong
    # and which every regex-shaped assertion in this file would still accept.
    @test occursin("INNER JOIN \"dim_cnes\" AS \"Tb_1\" ON \"Tb\".\"id\" = \"Tb_1\".\"unidade\"", sql)
end

@testset "Mixed-case binding - reverse filter routes to :where" begin
    q = MC.Dim_Unidade.objects
    q.values("nome")
    q.filter("dim_cnes__nome" => "unidade-x")

    insp = inspect_query(q)

    @test insp[:parameter_buckets][:where] == ["unidade-x"]
    @test contains(insp[:sql_text], "dim_cnes")
end

# ─────────────────────────────────────────────────────────────────────────────
# build_joins.jl — the multi-hop `new_object` loop, a SECOND mixed-case binding deep in the path.
# This also covers the `foreign_table_name` propagation: the first hop hands the resolved model to
# the next iteration, which before #343 received a respelled binding string and re-`getfield`ed it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Mixed-case binding - chained reverse join (build_joins loop)" begin
    q = MC.Dim_Unidade.objects
    q.values("nome", "dim_cnes__usuarios__login")

    sql = inspect_query(q)[:sql_text]

    @test contains(sql, "dim_cnes")
    @test contains(sql, "customuser")
    # Two reverse hops means at least two joins.
    @test length(collect(eachmatch(r"JOIN", sql))) >= 2

    # Both hops pinned literally — see the first-hop testset for why the regex form is not enough.
    # The second hop is the one that consumes the model handed forward by the first, so a break in
    # the `foreign_table_name` propagation shows up here as a wrong alias or a missing join.
    @test occursin("INNER JOIN \"dim_cnes\" AS \"Tb_1\" ON \"Tb\".\"id\" = \"Tb_1\".\"unidade\"", sql)
    @test occursin("INNER JOIN \"customuser\" AS \"Tb_2\" ON \"Tb_1\".\"id\" = \"Tb_2\".\"cnes\"", sql)
end

# ─────────────────────────────────────────────────────────────────────────────
# ctes.jl — `_resolve_join_target_model`, reached through on(). Sibling coverage for the
# lowercase-binding case lives in test_alignment_sqlite.jl "Related Objects - on() ...".
# ─────────────────────────────────────────────────────────────────────────────
@testset "Mixed-case binding - on() resolves the reverse target (ctes)" begin
    q = MC.Dim_Unidade.objects
    q.on("dim_cnes", "nome" => "on-value")
    q.values("nome", "dim_cnes__nome")

    insp = inspect_query(q)
    sql = insp[:sql_text]

    # on() puts the predicate in the ON clause, so its parameter lands in the :join bucket.
    @test insp[:parameter_buckets][:join] == ["on-value"]
    # #474 moved this assertion, and the oracle is in THIS file: the testset above renders the same
    # reverse hop with no on() at all and pins `INNER JOIN "dim_cnes" AS "Tb_1" ON ...`. It read
    # `contains(sql, "LEFT JOIN")`, which passed only because on() used to write a "LEFT" nobody
    # asked for — so the two testsets disagreed about the join type of one relation depending on
    # whether a predicate had been added to it. on() adds predicates; the type comes from the
    # relation. Pinned as the literal hop, matching the sibling testset, because a bare
    # `contains(sql, "INNER JOIN")` would not notice which join it landed on.
    @test occursin("INNER JOIN \"dim_cnes\" AS \"Tb_1\" ON \"Tb\".\"id\" = \"Tb_1\".\"unidade\"", sql)
    @test contains(sql, "dim_cnes")
end

@testset "Mixed-case binding - on() through a chained reverse path (ctes)" begin
    q = MC.Dim_Unidade.objects
    q.on("dim_cnes", "usuarios__login" => "chain-value")
    q.values("nome", "dim_cnes__nome")

    insp = inspect_query(q)

    @test "chain-value" in insp[:parameter_buckets][:join]
    # #474, same adjudication as the testset above. Both hops keep the type the sibling no-on()
    # testset pins for them; on() only contributes the predicate on the second one.
    @test occursin("INNER JOIN \"dim_cnes\" AS \"Tb_1\" ON \"Tb\".\"id\" = \"Tb_1\".\"unidade\"", insp[:sql_text])
    @test occursin("INNER JOIN \"customuser\" AS \"Tb_2\" ON \"Tb_1\".\"id\" = \"Tb_2\".\"cnes\"", insp[:sql_text])
end

# ─────────────────────────────────────────────────────────────────────────────
# deletion.jl — `find_related_objects!`. It walks related_objects to build the cascade plan and
# resolved the child by respelling the binding, so a cascade through Dim_CNES threw before #343.
# `show_query=:dict` builds the plan without executing it; the mock pool also short-circuits the
# related-existence probe, and the resolution happens before that check regardless.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Mixed-case binding - cascade delete plan (deletion)" begin
    q = MC.Dim_Unidade.objects.filter("id" => 7)

    insp = q.delete(show_query = :dict)

    # Inbound FKs mean a multi-step cascade plan rather than a single dict.
    @test insp isa Vector
    @test length(insp) >= 2

    # A step must target the mixed-case child's table, reached via its stored model.
    @test any(step -> contains(lowercase(step[:sql_text]), "dim_cnes"), insp)

    # The last step is the root DELETE on the model we asked to delete.
    root_step = insp[end]
    @test root_step[:operation] == :delete
    @test contains(lowercase(root_step[:model]), "dim_unidade")

    for step in insp
        @test haskey(step, :operation)
        @test haskey(step, :sql_text)
        @test step[:operation] in (:delete, :update)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# The relation is shared, not cloned, and re-registration reproduces an EQUAL one. #343 removed
# ManyToManyRelation's hand-written deepcopy hook on the strength of this property, so pin it for
# the struct that replaced the tuple.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Mixed-case binding - ReverseRelation deepcopy shares and set_models is idempotent" begin
    rel = MC.Dim_Unidade.related_objects["dim_cnes"]
    copy_rel = deepcopy(rel)

    # An immutable whose every field is `===`-stable is itself `===`-stable: the Symbols are
    # interned and the model routes through the Model_Type share hook (#157) rather than descending
    # into `_module::Module`, which would throw.
    @test copy_rel.model_resolved === MC.Dim_CNES
    @test copy_rel === rel

    original = deepcopy(MC.Dim_Unidade.related_objects)
    PormG.Models.set_models(MC, "mixed_case_binding_mock")
    @test MC.Dim_Unidade.related_objects == original
    @test MC.Dim_Unidade.related_objects["dim_cnes"].binding === :Dim_CNES
end
