# ─────────────────────────────────────────────────────────────────────────────
# alter_field constraint-DROP branches: dispatch and empty-result contracts
# (#283, #284)
#
# `alter_field(::PormGPostgres, table_name, field_name, …)` accepts
# `Union{Symbol,String}` for both names, but the three `get_constraints_*`
# introspection helpers it calls declared different concrete argument types, and
# the primary-key branch called one of them with the wrong arity entirely. The
# result was a `MethodError` on a code path that only fires when a migration
# DROPS a primary key or a unique constraint — rare enough that no test reached it.
#
# Separately, two helpers annotated `::String` while returning `nothing` for
# "no such constraint", so the empty-result branch raised a conversion error
# instead of letting the caller's `!== nothing` guard do its job.
#
# Pure SQL-shape tests — no live DB. Follows the mock pattern established by
# test_positive_small_integer_check.jl.
# ─────────────────────────────────────────────────────────────────────────────

using Test
using PormG
using PormG.Models
using DataFrames

# Mock connection names carry a `283` suffix on purpose: several unit files already
# define a bare `MockPostgres`, and because runtests.jl includes them all into one
# session a duplicate name silently redefines the struct for whichever file runs later.
struct MockPgPkNamed283 <: PormG.PormGPostgres end
PormG.get_constraints_pk(::MockPgPkNamed283, table_name::String, field_name::String) = "circuits_pkey"

struct MockPgPkNone283 <: PormG.PormGPostgres end
PormG.get_constraints_pk(::MockPgPkNone283, table_name::String, field_name::String) = nothing

struct MockPgUniqueNamed283 <: PormG.PormGPostgres end
PormG.get_constraints_unique(::MockPgUniqueNamed283, table_name::String, field_name::String) = "circuits_alt_key"

struct MockPgUniqueNone283 <: PormG.PormGPostgres end
PormG.get_constraints_unique(::MockPgUniqueNone283, table_name::String, field_name::String) = nothing

# For #284 we exercise the REAL introspection bodies, so the mock intercepts one layer
# lower: `fetch` (which PormG extends from Base) returns an empty DataFrame, driving the
# `nrow(result) == 0` branch without a database.
struct MockPgEmptyResult283 <: PormG.PormGPostgres end
Base.fetch(::MockPgEmptyResult283, sql::String; kwargs...) = DataFrame()

@testset "alter_field constraint DROP branches (#283, #284)" begin

  # ───────────────────────────────────────────────────────────────────────────
  # #283 — dropping a PRIMARY KEY.
  # The branch fires when :primary_key is in colect_not_equal and the new field is
  # NOT a primary key. Before the fix this raised MethodError: the call passed two
  # arguments to a three-argument method, and the only method wanted a Symbol table
  # name while alter_field's own model-based overload always supplies a String.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "drops the primary key by its introspected name" begin
    new_field = Models.CharField(primary_key = false)
    old_field = Models.CharField(primary_key = true)

    sql = PormG.Dialect.alter_field(MockPgPkNamed283(), "circuits", "alt",
                                    new_field, old_field, Symbol[:primary_key])

    # Assert the WHOLE statement, not a fragment: the table name, the constraint name
    # and the terminating semicolon are all knowable, so a regression in any of them
    # should fail rather than slip past a substring match.
    @test sql == "ALTER TABLE \"circuits\" DROP CONSTRAINT \"circuits_pkey\";"
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Discrimination: the other side of the `contrains !== nothing` guard. A table with
  # no matching primary-key constraint must emit NOTHING, rather than a
  # `DROP CONSTRAINT "nothing"`. The empty string is the exact contract.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "emits no DROP when no primary-key constraint exists" begin
    new_field = Models.CharField(primary_key = false)
    old_field = Models.CharField(primary_key = true)

    sql = PormG.Dialect.alter_field(MockPgPkNone283(), "circuits", "alt",
                                    new_field, old_field, Symbol[:primary_key])

    @test sql == ""
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Control, not #283 coverage: this branch passed before the fix too. It guards the
  # OTHER side of the `if new_field.primary_key` split — turning a column INTO a
  # primary key must ADD one and never consult introspection at all.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "adds a primary key without touching introspection" begin
    new_field = Models.CharField(primary_key = true)
    old_field = Models.CharField(primary_key = false)

    # MockPgPkNone283 would return `nothing`; if the ADD path wrongly called
    # introspection we would still get no DROP, so assert the ADD is present.
    sql = PormG.Dialect.alter_field(MockPgPkNone283(), "circuits", "alt",
                                    new_field, old_field, Symbol[:primary_key])

    @test occursin("ADD PRIMARY KEY (\"alt\")", sql)
    @test !occursin("DROP CONSTRAINT", sql)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # #283 — the real production entry point.
  # Every `Dialect.alter_field` call site in src/ (planner.jl:264, 367, 464, 544)
  # goes through the `model::PormGModel` overload, which resolves the table as
  # `model.name |> lowercase` before delegating here. This exercises that whole
  # chain rather than the bare 3-arg form, so it pins the path migrations take.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "drops the primary key through the model overload" begin
    model = Models.Model("circuits", alt = Models.CharField(primary_key = false))
    new_field = Models.CharField(primary_key = false)
    old_field = Models.CharField(primary_key = true)

    sql = PormG.Dialect.alter_field(MockPgPkNamed283(), model, "alt",
                                    new_field, old_field, Symbol[:primary_key])

    @test occursin("ALTER TABLE \"circuits\" DROP CONSTRAINT \"circuits_pkey\";", sql)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # #283 — dropping a UNIQUE constraint: same branch shape, same coercion gap.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "drops a unique constraint by its introspected name" begin
    new_field = Models.CharField(unique = false)
    old_field = Models.CharField(unique = true)

    sql = PormG.Dialect.alter_field(MockPgUniqueNamed283(), "circuits", "alt",
                                    new_field, old_field, Symbol[:unique])

    # Assert the WHOLE statement: a regression that emitted the right constraint name
    # against the wrong table would still satisfy a fragment match.
    @test sql == "ALTER TABLE \"circuits\" DROP CONSTRAINT \"circuits_alt_key\";"
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Discrimination for the unique branch: no constraint found means no statement at
  # all. `alter_field` returns "" here, which is the exact knowable contract.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "emits no DROP when no unique constraint exists" begin
    new_field = Models.CharField(unique = false)
    old_field = Models.CharField(unique = true)

    sql = PormG.Dialect.alter_field(MockPgUniqueNone283(), "circuits", "alt",
                                    new_field, old_field, Symbol[:unique])

    @test sql == ""
  end

  # ───────────────────────────────────────────────────────────────────────────
  # #284 — the empty-result contract of the introspection helpers themselves.
  # These call the REAL bodies with `fetch` mocked to return zero rows. With the
  # `::String` return annotation Julia converts the `return nothing`, so the call
  # raised `MethodError: Cannot convert an object of type Nothing to ... String`
  # instead of returning the `nothing` its own caller tests for.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "introspection helpers return nothing on an empty result" begin
    conn = MockPgEmptyResult283()

    @test PormG.Migrations.get_constraints_unique(conn, "circuits", "alt") === nothing
    @test PormG.Migrations.get_sequence_name(conn, "circuits", "alt") === nothing

    # The two siblings that were already correct — pinned so the contract stays uniform
    # across the family rather than being fixed for two of four.
    @test PormG.Migrations.get_constraints_pk(conn, "circuits", "alt") === nothing
    @test PormG.Migrations.get_constraints_check(conn, "circuits", "alt") === nothing
  end
end
