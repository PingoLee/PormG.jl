"""
Unit coverage for declared field-name CASE PRESERVATION (#57).

PormG preserves the case you declare a field with: `driverId = IDField()` registers the
field as `driverId` (not `driverid`), its column renders `"driverId"`, queries resolve it
case-sensitively, and the migration diff compares case-correctly. This is what lets PormG
faithfully target mixed-case / uppercase DB columns (e.g. legacy Django schemas).

Table/model names stay LOWERCASE (frozen schema convention, #33) — only field/column
names preserve case. Since #300 that is enforced rather than conventional: a positional
model name containing uppercase is rejected at declaration. The PormG-internal house style
is lowercase snake_case (#58); this file deliberately uses a mixed-case mechanics model —
mixed-case COLUMNS on a lowercase table — to exercise the preservation path.

All assertions render via a mock PostgreSQL connection (no live database required).
"""

using Test
using PormG
using PormG.Models: Model, CharField, IDField, ForeignKey, format_fild_name, are_model_fields_equal
using PormG.QueryBuilder: inspect_query

# Dedicated mock connection — uniquely named so it never clashes with other unit files'
# mock structs when runtests.jl includes them into the same module.
struct MockPostgresFieldCase <: PormG.PormGPostgres end
PormG.config["default"] = PormG.Configuration.Settings(
  connections = MockPostgresFieldCase(),
  change_data = true,
)

# Mixed-case mechanics fixture: a legacy-style model whose columns are camelCase.
LegacyEntryCase = Model("legacy_entry_case_scratch",
  driverId = IDField(),
  foreName = CharField(),
  raceId   = ForeignKey("LegacyRaceCase", pk_field="raceId", on_delete="CASCADE", null=true),
)
LegacyEntryCase.connect_key = "default"

@testset "Field-name case preservation (#57)" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # format_fild_name PRESERVES case. It is the single function every field name flows
  # through, and since #317 it rewrites nothing at all — it only validates. (It used to
  # also strip one leading underscore, the retired reserved-word escape hatch.)
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "format_fild_name preserves declared case" begin
    @test format_fild_name("driverId")  == "driverId"
    @test format_fild_name("foreName")  == "foreName"
    @test format_fild_name("_DriverId") == "_DriverId"  # verbatim: no strip (#317), case kept
    @test format_fild_name("driverid")  == "driverid"   # lowercase passes through unchanged
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Field identity is the declared case; the lowercased form is NOT registered.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "field identity preserves case" begin
    @test "driverId" in LegacyEntryCase.field_names
    @test "foreName" in LegacyEntryCase.field_names
    @test "raceId"   in LegacyEntryCase.field_names
    @test !("driverid" in LegacyEntryCase.field_names)
    @test !("forename" in LegacyEntryCase.field_names)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Queries render the declared-case column verbatim-quoted in WHERE/SELECT; the
  # lowercase path is rejected (case-sensitive lookup) at build time.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "query renders preserved case; lowercase path throws" begin
    q = LegacyEntryCase.objects
    q.filter("foreName" => "Ayrton")
    q.values("driverId", "foreName")
    insp = inspect_query(q)
    @test occursin("\"Tb\".\"foreName\" = \$1", insp[:sql_text])
    @test occursin("\"Tb\".\"driverId\"", insp[:sql_text])
    @test insp[:parameters] == ["Ayrton"]

    bad = LegacyEntryCase.objects
    bad.filter("forename" => "Ayrton")          # wrong case
    # Broad matcher is intentional: the concrete type depends on the clause — a wrong-case
    # filter key fails a `model.fields[...]` lookup (KeyError), while values()/order_by()
    # reach `_solve_field` (ArgumentError). The contract under test is "rejected at build", not
    # a specific exception type. Do not narrow this without checking the actual clause's path.
    @test_throws Exception inspect_query(bad)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # UPDATE SET-clause and ORDER BY flow through the same _solve_field path as
  # filter/values, so they too render the declared-case column verbatim-quoted.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "update SET and order_by render preserved case" begin
    upd = LegacyEntryCase.objects.filter("driverId" => 1).update("foreName" => "Ayrton", show_query=:sql)
    @test upd isa String
    @test occursin("UPDATE", uppercase(upd))
    @test occursin("\"foreName\"", upd)

    oq = LegacyEntryCase.objects
    oq.order_by("foreName")
    osql = inspect_query(oq)[:sql_text]
    @test occursin("order by", lowercase(osql))
    @test occursin("\"foreName\"", osql)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # DDL: column names preserve case (quoted); the table name is lowercased.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "create_table preserves column case, lowercases table" begin
    ddl = PormG.Dialect.create_table(MockPostgresFieldCase(), LegacyEntryCase)
    @test occursin("\"driverId\"", ddl)
    @test occursin("\"foreName\"", ddl)
    @test occursin("\"raceId\"", ddl)
    @test occursin("legacy_entry_case_scratch", ddl)   # table name is lowercase (enforced, #300)
    @test !occursin("\"driverid\"", ddl)               # no lowercased columns leak in
    @test !occursin("\"forename\"", ddl)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Delete-key resolution returns the declared-case primary key (no lowercasing) so
  # the DELETE WHERE clause targets the real column.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "resolve_delete_key preserves case" begin
    @test PormG.QueryBuilder.resolve_delete_key(LegacyEntryCase) == "driverId"
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Migration diff is case-sensitive: an identical-case model diffs clean (no churn),
  # while a lowercase variant is seen as a different schema (proving case matters).
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "migration diff is case-sensitive (no spurious churn)" begin
    same = Model("legacy_entry_case_scratch",
      driverId = IDField(),
      foreName = CharField(),
      raceId   = ForeignKey("LegacyRaceCase", pk_field="raceId", on_delete="CASCADE", null=true),
    )
    lowered = Model("legacy_entry_case_scratch",
      driverid = IDField(),
      forename = CharField(),
      raceid   = ForeignKey("LegacyRaceCase", pk_field="raceid", on_delete="CASCADE", null=true),
    )
    @test are_model_fields_equal(LegacyEntryCase, same)      # identical case → no diff
    @test !are_model_fields_equal(LegacyEntryCase, lowered)  # case differs → not equal
  end

end
