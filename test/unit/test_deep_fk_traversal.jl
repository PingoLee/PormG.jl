"""
Unit tests for deep (3-hop) ForeignKey traversal SQL generation.

`test_complex_queries.jl` covers Django short-form joins up to 2 hops
(`result__driver__forename`). Downstream consumers traverse FK chains three hops
deep using the *explicit* FK field-name convention (e.g. `personid__cityid__countryid__name`),
which walks the join builder's loop one level further and emits a third `INNER JOIN`.

This file pins that 3-hop contract — number/shape of joins, ON predicates, the leaf
column in both `.filter()` and `.values()`, and parameter binding — with no live DB
(`show_query=:dict`). A regression in the join walker that silently dropped or
mis-aliased the third hop would otherwise pass every existing unit test.
"""

using Test
using PormG
using PormG.Models: Model, CharField, IDField, IntegerField, ForeignKey

# ---------------------------------------------------------------------------
# A 4-table FK chain: Visit → person → city → country.
#   Visit.personid    → Person.id
#   Person.cityid     → City.id
#   City.countryid    → Country.id
# Traversing "personid__cityid__countryid__name" is three FK hops to a leaf column.
# _module must be set so the join walker can resolve related models by name.
# ---------------------------------------------------------------------------
if !isdefined(Main, :_DeepCountry)
  _DeepCountry = Model("country", id = IDField(), name = CharField())
  _DeepCountry.connect_key = "default"; _DeepCountry._module = Main

  _DeepCity = Model("city",
    id        = IDField(),
    name      = CharField(),
    countryid = ForeignKey(_DeepCountry, pk_field="id"),
  )
  _DeepCity.connect_key = "default"; _DeepCity._module = Main

  _DeepPerson = Model("person",
    id     = IDField(),
    name   = CharField(),
    cityid = ForeignKey(_DeepCity, pk_field="id"),
  )
  _DeepPerson.connect_key = "default"; _DeepPerson._module = Main

  _DeepVisit = Model("visit",
    id       = IDField(),
    personid = ForeignKey(_DeepPerson, pk_field="id"),
  )
  _DeepVisit.connect_key = "default"; _DeepVisit._module = Main

  struct _MockPostgresDeep <: PormG.PormGPostgres end
  PormG.config["default"] = PormG.Configuration.Settings(
    connections = _MockPostgresDeep(),
    change_data = true,
  )
end

const _V = _DeepVisit

@testset "Deep FK traversal (3 hops)" begin

  # =========================================================================
  # 1. Three-hop traversal in .filter()
  # =========================================================================
  @testset "filter() emits three INNER JOINs to the leaf column" begin
    res = _V.objects.filter("personid__cityid__countryid__name" => "Brazil").list(show_query=:dict)
    sql = res[:sql_text]

    # Exactly three joins — one per hop.
    @test length(collect(eachmatch(r"INNER JOIN", sql))) == 3
    @test contains(sql, "\"person\"")
    @test contains(sql, "\"city\"")
    @test contains(sql, "\"country\"")
    # ON predicates chain through the FK columns hop by hop.
    @test contains(sql, "\"Tb\".\"personid\" = \"Tb_1\".\"id\"")
    @test contains(sql, "\"Tb_1\".\"cityid\" = \"Tb_2\".\"id\"")
    @test contains(sql, "\"Tb_2\".\"countryid\" = \"Tb_3\".\"id\"")
    # Leaf comparison lives on the last alias and is parameterised.
    @test contains(sql, "\"Tb_3\".\"name\" = \$1")
    @test res[:parameters] == ["Brazil"]
  end

  # =========================================================================
  # 2. Three-hop traversal in .values() (SELECT projection)
  # =========================================================================
  @testset "values() projects the 3-hop leaf column with its alias" begin
    res = _V.objects.values("c" => "personid__cityid__countryid__name").list(show_query=:dict)
    sql = res[:sql_text]

    @test length(collect(eachmatch(r"INNER JOIN", sql))) == 3
    # Leaf column selected from the deepest alias, aliased back to "c".
    @test contains(sql, "\"Tb_3\".\"name\" as \"c\"")
  end

  # =========================================================================
  # 3. Two-hop prefix still resolves (guards against off-by-one in the walker)
  # =========================================================================
  @testset "two-hop prefix emits two INNER JOINs" begin
    res = _V.objects.filter("personid__cityid__name" => "Recife").list(show_query=:dict)
    sql = res[:sql_text]

    @test length(collect(eachmatch(r"INNER JOIN", sql))) == 2
    @test contains(sql, "\"Tb_2\".\"name\" = \$1")
    @test res[:parameters] == ["Recife"]
  end

end
