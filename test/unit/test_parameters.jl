using Test
using PormG
using PormG.QueryBuilder

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
    
    # Unknown context fallback (treat as :where)
    QB.set_context!(params, :something_wrong)
    QB.add_parameter!(params, 4)
    @test params.where_params[end] == 4
end

@testset "LIKE patterns (contains=true)" begin
    # SQLite
    sl_params = QB.SQLiteParameterizedQuery()
    QB.set_context!(sl_params, :where)
    QB.add_parameter!(sl_params, "apple", contains=true)
    @test sl_params.where_params[1] == "%apple%"
    
    # Postgres
    pg_params = QB.PgParameterizedQuery("", Any[], 0)
    QB.add_parameter!(pg_params, "banana", contains=true)
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
    QB.set_context!(params, :cte); QB.add_parameter!(params, "c")
    QB.set_context!(params, :select); QB.add_parameter!(params, "s")
    QB.set_context!(params, :update); QB.add_parameter!(params, "u")
    QB.set_context!(params, :join); QB.add_parameter!(params, "j")
    QB.set_context!(params, :where); QB.add_parameter!(params, "w")
    QB.set_context!(params, :having); QB.add_parameter!(params, "h")
    
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

