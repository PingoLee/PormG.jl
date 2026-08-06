using Test
using PormG
using PormG.QueryBuilder
using Logging

# The internal types are not exported, so we access them via PormG.QueryBuilder
const QB = PormG.QueryBuilder

@testset "Contextual Buckets Strategy (SQLite)" begin
    # 1. Initialize a positional parameter object (SQLite)
    # The default context is :where
    params = QB.SQLiteParameterizedQuery()
    @test params.current_context === :where
    @test QB.get_final_parameters(params) == Any[]

    # 2. Add parameters in "wrong" execution order (how PormG builds queries)
    # Logic: CTE (1) -> SELECT (2) -> UPDATE (3) -> JOIN (4) -> WHERE (5) -> HAVING (6)

    # Simulate WHERE clause building (Phase 1 in Julia logic)
    QB.set_context!(params, :where)
    QB.add_parameter!(params, "where_val")

    # Simulate HAVING clause building (Phase 2)
    QB.set_context!(params, :having)
    QB.add_parameter!(params, "having_val")

    # Simulate JOIN clause building (Phase 3)
    QB.set_context!(params, :join)
    QB.add_parameter!(params, "join_val")

    # Simulate UPDATE (SET) clause building (Phase 4)
    QB.set_context!(params, :update)
    QB.add_parameter!(params, "update_val")

    # Simulate SELECT clause building (Phase 5)
    QB.set_context!(params, :select)
    QB.add_parameter!(params, "select_val")

    # Simulate CTE (WITH) building (Phase 6)
    QB.set_context!(params, :cte)
    QB.add_parameter!(params, "cte_val")

    # 3. Verify final concatenation order matches SQL clause order:
    # CTE -> SELECT -> UPDATE -> JOIN -> WHERE -> HAVING
    final_params = QB.get_final_parameters(params)
    @test length(final_params) == 6
    @test final_params == ["cte_val", "select_val", "update_val", "join_val", "where_val", "having_val"]

    # 4. Property access compatibility
    @test params.parameters == final_params
end

@testset "Re-entry and Safety" begin
    params = QB.SQLiteParameterizedQuery()

    # Interleaving buckets - shouldn't matter as long as context is set
    QB.set_context!(params, :where)
    QB.add_parameter!(params, 1)

    QB.set_context!(params, :select)
    QB.add_parameter!(params, 2)

    # Return to where
    QB.set_context!(params, :where)
    QB.add_parameter!(params, 3)

    final = QB.get_final_parameters(params)
    @test final == [2, 1, 3] # select (2) -> where (1, 3)

    # Unknown context fallback (treat as :where). The warning itself is expected and useful in
    # production, but the unit suite should stay quiet because this test intentionally triggers
    # the fallback path as a behavioral assertion rather than an operator-facing warning check.
    Base.CoreLogging.with_logger(Logging.NullLogger()) do
        QB.set_context!(params, :something_wrong)
        QB.add_parameter!(params, 4)
    end
    @test params.where_params[end] == 4
end

@testset "LIKE patterns (contains=true)" begin
    # SQLite
    sl_params = QB.SQLiteParameterizedQuery()
    QB.set_context!(sl_params, :where)
    QB.add_parameter!(sl_params, "apple", contains=true, operator="contains")
    @test sl_params.where_params[1] == "%apple%"

    # Postgres
    pg_params = QB.PgParameterizedQuery("", Any[], 0)
    QB.add_parameter!(pg_params, "banana", contains=true, operator="contains")
    @test pg_params.parameters[1] == "%banana%"
end

@testset "PostgreSQL Numbered Parameters Compatibility" begin
    params = QB.PgParameterizedQuery("", Any[], 0)

    # Context switches should be no-ops
    QB.set_context!(params, :where)
    p1 = QB.add_parameter!(params, "val1")
    @test p1 == "\$1"

    QB.set_context!(params, :join)
    p2 = QB.add_parameter!(params, "val2")
    @test p2 == "\$2"

    final_params = QB.get_final_parameters(params)
    @test final_params == ["val1", "val2"]
end

@testset "PostgreSQL Typed Placeholders" begin
    params = QB.PgParameterizedQuery("", Any[], 0)

    # PostgreSQL cannot infer the type of a bare SELECT-side placeholder like `$1`.
    # The parameter layer now allows callers to request an explicit SQL cast while
    # still keeping the bound Julia value in the parameter vector.
    string_placeholder = QB.add_parameter!(params, "-Q", sql_type="text")
    int_placeholder = QB.add_parameter!(params, 4, sql_type="integer")

    @test string_placeholder == "\$1::text"
    @test int_placeholder == "\$2::integer"
    @test QB.get_final_parameters(params) == ["-Q", 4]
end

@testset "Array Parameter Expansion (SQLite)" begin
    params = QB.SQLiteParameterizedQuery()
    QB.set_context!(params, :where)

    # Mixed scalar and array
    QB.add_parameter!(params, "start")
    p_array = QB.add_parameter!(params, [10, 20])
    QB.add_parameter!(params, "end")

    @test p_array == "?, ?"
    @test QB.get_final_parameters(params) == ["start", 10, 20, "end"]
    @test params.parameter_count == 4
end

@testset "Subquery Simulated Inheritance" begin
    # In PormG, subqueries often use the parent's parameter object
    parent_params = QB.SQLiteParameterizedQuery()

    # Building main query SELECT clause
    QB.set_context!(parent_params, :select)
    QB.add_parameter!(parent_params, "parent_select")

    # "Subquery" starts here, it should inherit context or set its own
    # If it wants to land in SELECT, it shouldn't change context if already there,
    # or it should set it to :select explicitly.
    function mock_build_subquery(p)
        QB.set_context!(p, :select) # Subquery in SELECT clause
        QB.add_parameter!(p, "sub_val")
        return "(SELECT ?)"
    end

    mock_build_subquery(parent_params)

    # Back to parent logic (building WHERE)
    QB.set_context!(parent_params, :where)
    QB.add_parameter!(parent_params, "parent_where")

    final = QB.get_final_parameters(parent_params)
    @test final == ["parent_select", "sub_val", "parent_where"]
end

@testset "Deep Copy Support (Diversity)" begin
    params = QB.SQLiteParameterizedQuery()
    QB.set_context!(params, :cte)
    QB.add_parameter!(params, "c")
    QB.set_context!(params, :select)
    QB.add_parameter!(params, "s")
    QB.set_context!(params, :update)
    QB.add_parameter!(params, "u")
    QB.set_context!(params, :join)
    QB.add_parameter!(params, "j")
    QB.set_context!(params, :where)
    QB.add_parameter!(params, "w")
    QB.set_context!(params, :having)
    QB.add_parameter!(params, "h")

    params_copy = deepcopy(params)
    @test QB.get_final_parameters(params_copy) == ["c", "s", "u", "j", "w", "h"]
    @test params_copy !== params

    # Mutate copy
    QB.set_context!(params_copy, :select)
    QB.add_parameter!(params_copy, "s2")

    @test length(params.select_params) == 1
    @test length(params_copy.select_params) == 2

    # Check hasproperty for update_params
    @test hasproperty(params, :update_params)
end

@testset "Mock QueryBuilder Pipeline" begin
    # This simulates the EXACT order of calls in QueryBuilder.build()
    params = QB.SQLiteParameterizedQuery()

    # 1. SELECT phase
    QB.set_context!(params, :select)
    QB.add_parameter!(params, "col1_val")

    # 2. WHERE phase
    QB.set_context!(params, :where)
    QB.add_parameter!(params, "filter_val")

    # 3. JOIN phase (Crucial: processed AFTER where, but SQL order is BEFORE)
    QB.set_context!(params, :join)
    QB.add_parameter!(params, "join_val")

    final = QB.get_final_parameters(params)
    # Expected: SELECT -> JOIN -> WHERE
    @test final == ["col1_val", "join_val", "filter_val"]
end


# ─────────────────────────────────────────────────────────────────────────────
# BinaryField payloads: one blob, not a list of values (#296)
# `PormGBytes` must beat the `::AbstractArray` methods on both backends. Before the
# wrapper existed a `Vector{UInt8}` took the array path, which is wrong in opposite
# ways per backend: SQLite expanded it into one `?` per BYTE (statement fails on a
# column-count mismatch), and PostgreSQL handed the vector to LibPQ, which renders any
# vector as a PG array literal in text format — so `UInt8[0x00, 0xFF]` reached the
# server as the five characters `{0,255}` and `bytea`'s escape-format parser stored
# those ASCII bytes. That one raised no error at all; it silently corrupted the column.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Binary payloads bind as a single blob (#296)" begin
    payload = UInt8[0x00, 0xFF, 0x89, 0x50]

    @testset "SQLite: one placeholder, bytes passed through unwrapped" begin
        params = QB.SQLiteParameterizedQuery()
        QB.set_context!(params, :where)

        placeholder = QB.add_parameter!(params, PormG.PormGBytes(payload))

        # Exactly ONE `?` — the bug was `?, ?, ?, ?`, one per byte.
        @test placeholder == "?"
        final = QB.get_final_parameters(params)
        @test length(final) == 1
        # Unwrapped: SQLite.jl binds a Vector{UInt8} natively via sqlite3_bind_blob, but its
        # `bind!(::Any)` fallback would silently Julia-*serialize* an unrecognized wrapper
        # into a BLOB rather than raise, so the unwrap here is load-bearing.
        @test final[1] isa Vector{UInt8}
        @test final[1] == payload
    end

    @testset "SQLite: a bare Vector{UInt8} still expands (IN-list behaviour preserved)" begin
        # Dispatching the fix on the bare type would have hijacked every value list in the
        # builder, e.g. filter("x__in" => UInt8[1, 2]). Only values routed through a binary
        # field's formatter get the blob treatment.
        params = QB.SQLiteParameterizedQuery()
        QB.set_context!(params, :where)

        placeholder = QB.add_parameter!(params, UInt8[0x01, 0x02])

        @test placeholder == "?, ?"
        @test QB.get_final_parameters(params) == Any[0x01, 0x02]
    end

    @testset "PostgreSQL: hex-encoded text parameter, not an array literal" begin
        params = QB.PgParameterizedQuery("", Any[], 0)

        placeholder = QB.add_parameter!(params, PormG.PormGBytes(payload))

        @test placeholder == "\$1"
        @test length(params.parameters) == 1
        # LibPQ binds every parameter in text format and has no binary-parameter API, so the
        # wire form must be PostgreSQL's hex input syntax. The server infers bytea from the
        # target column and `byteain` decodes it exactly.
        @test params.parameters[1] == "\\x00ff8950"
        # Explicitly NOT the array literal that caused the silent corruption.
        @test params.parameters[1] != "{0,255,137,80}"
        @test !(params.parameters[1] isa AbstractVector)
    end

    @testset "PostgreSQL: an empty payload is still one parameter" begin
        params = QB.PgParameterizedQuery("", Any[], 0)
        @test QB.add_parameter!(params, PormG.PormGBytes(UInt8[])) == "\$1"
        @test params.parameters[1] == "\\x"
    end

    @testset "0x00 survives — the byte a String parameter could never carry" begin
        # LibPQ passes String parameters as NUL-terminated C strings, so a raw byte payload
        # containing 0x00 would be truncated there regardless of encoding. Hex sidesteps it.
        params = QB.PgParameterizedQuery("", Any[], 0)
        QB.add_parameter!(params, PormG.PormGBytes(UInt8[0x41, 0x00, 0x42]))
        @test params.parameters[1] == "\\x410042"
    end

    @testset "LIKE wildcards are rejected on binary parameters" begin
        # `contains` decorates a value with % wildcards via string interpolation, which is
        # meaningless for bytes — fail loudly rather than stringify the payload.
        sl = QB.SQLiteParameterizedQuery()
        pg = QB.PgParameterizedQuery("", Any[], 0)
        @test_throws PormG.FilterError QB.add_parameter!(sl, PormG.PormGBytes(payload); contains=true, operator="contains")
        @test_throws PormG.FilterError QB.add_parameter!(pg, PormG.PormGBytes(payload); contains=true, operator="contains")
    end
end
