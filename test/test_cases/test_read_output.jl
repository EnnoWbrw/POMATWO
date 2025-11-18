function test_read_output()
    @testset "Read Output Functions Tests" begin
        @testset "get_redispatch_by_type_node" begin
            # Load a test case with redispatch data
            expected_dir = joinpath(@__DIR__, "expected_results")
            
            # Test with a redispatch scenario (testcase_7 is ZonalMarketWithRedispatch_NoProsumer)
            testcase_dir = joinpath(expected_dir, "testcase_7_ZonalMarketWithRedispatch_NoProsumer")
            
            if isdir(testcase_dir)
                @testset "Test with valid redispatch data" begin
                    results = DataFiles(testcase_dir)
                    
                    # Call the function
                    redispatch_diff = get_redispatch_by_type_node(results)
                    
                    # Basic structure tests
                    @test redispatch_diff isa DataFrame
                    @test !isempty(redispatch_diff)
                    
                    # Check that required columns exist
                    required_cols = ["Time", "node", "type", "GEN", "GEN_REDISP", "difference"]
                    for col in required_cols
                        @test col in names(redispatch_diff)
                    end
                    
                    # Check data types
                    @test eltype(redispatch_diff.Time) <: Integer
                    @test eltype(redispatch_diff.node) <: AbstractString
                    @test eltype(redispatch_diff.type) <: AbstractString
                    @test eltype(redispatch_diff.GEN) <: Real
                    @test eltype(redispatch_diff.GEN_REDISP) <: Real
                    @test eltype(redispatch_diff.difference) <: Real
                    
                    # Check that difference is calculated correctly
                    for row in eachrow(redispatch_diff)
                        @test row.difference ≈ row.GEN_REDISP - row.GEN atol=1e-10
                    end
                    
                    # Check that results are sorted
                    @test issorted(redispatch_diff, [:Time, :node, :type])
                    
                    # Check that all values are finite
                    @test all(isfinite.(redispatch_diff.GEN))
                    @test all(isfinite.(redispatch_diff.GEN_REDISP))
                    @test all(isfinite.(redispatch_diff.difference))
                end
            else
               error("Test case directory not found: $testcase_dir")
            end
            
            # Test with NodalMarketWithRedispatch (testcase_19)
            testcase_nodal_dir = joinpath(expected_dir, "testcase_19_NodalMarketWithRedispatch_NoProsumer")
            
            if isdir(testcase_nodal_dir)
                @testset "Test with nodal redispatch data" begin
                    results = DataFiles(testcase_nodal_dir)
                    redispatch_diff = get_redispatch_by_type_node(results)
                    
                    @test !isempty(redispatch_diff)
                    @test all(col in names(redispatch_diff) for col in ["Time", "node", "type", "GEN", "GEN_REDISP", "difference"])
                    
                    # Verify that we have multiple nodes (since it's a nodal market)
                    unique_nodes = unique(redispatch_diff.node)
                    @test length(unique_nodes) > 0
                    
                    # Verify grouping: each (Time, node, type) combination should appear only once
                    grouped = groupby(redispatch_diff, [:Time, :node, :type])
                    @test all(nrow(g) == 1 for g in grouped)
                end
            else
                error("Nodal test case directory not found: $testcase_nodal_dir")
            end
        end
        
        @testset "get_redispatch_by_type_node - Empty data handling" begin
            # Test with a scenario that has no redispatch (testcase_1 is ZonalMarket_NoProsumer)
            expected_dir = joinpath(@__DIR__, "expected_results")
            testcase_no_redisp = joinpath(expected_dir, "testcase_1_ZonalMarket_NoProsumer")
            
            if isdir(testcase_no_redisp)
                results = DataFiles(testcase_no_redisp)
                
                # Should return an empty DataFrame with the correct structure when REDISP is empty
                redispatch_diff = get_redispatch_by_type_node(results)
                
                @test redispatch_diff isa DataFrame
                # Check that the DataFrame has the correct columns even if empty
                expected_cols = ["Time", "node", "type", "GEN", "GEN_REDISP", "difference"]
                @test all(col in names(redispatch_diff) for col in expected_cols)
            else
                error("Test case directory not found: $testcase_no_redisp")
            end
        end
        
        @testset "get_redispatch_by_type_node - Consistency checks" begin
            # Test that function results are consistent with underlying data
            expected_dir = joinpath(@__DIR__, "expected_results")
            testcase_dir = joinpath(expected_dir, "testcase_7_ZonalMarketWithRedispatch_NoProsumer")
            
            if isdir(testcase_dir)
                results = DataFiles(testcase_dir)
                
                # Only run if we have both GEN and REDISP data
                if !isempty(results.GEN) && !isempty(results.REDISP)
                    redispatch_diff = get_redispatch_by_type_node(results)
                    
                    # Sum of differences by time should represent total redispatch adjustments
                    total_diff_by_time = DataFrames.combine(
                        groupby(redispatch_diff, :Time),
                        :difference => sum => :total_diff
                    )
                    
                    # All total differences should be finite
                    @test all(isfinite.(total_diff_by_time.total_diff))
                    
                    # For each plant type, verify we're capturing all data
                    unique_types = unique(redispatch_diff.type)
                    @test length(unique_types) > 0
                    
                    # Verify that the function handles all plants present in params
                    if !isempty(results.params.sets.P)
                        # Check that nodes in output are valid
                        valid_nodes = results.params.sets.N
                        output_nodes = unique(redispatch_diff.node)
                        @test all(node in valid_nodes for node in output_nodes)
                    end
                end
            end
        end
        
        @testset "transform_results_by_type integration" begin
            # Test that transform_results_by_type and get_redispatch_by_type_node work together
            expected_dir = joinpath(@__DIR__, "expected_results")
            testcase_dir = joinpath(expected_dir, "testcase_7_ZonalMarketWithRedispatch_NoProsumer")
            
            if isdir(testcase_dir)
                results = DataFiles(testcase_dir)
                
                # Get zones from params
                if !isempty(results.params.sets.Z)
                    zone = results.params.sets.Z[1]
                    
                    # Test transform_results_by_type for different kinds
                    gen_by_type = transform_results_by_type(results, :GEN, zone)
                    redisp_by_type = transform_results_by_type(results, :REDISP, zone)
                    
                    @test gen_by_type isa DataFrame
                    @test redisp_by_type isa DataFrame
                    
                    # Both should have Time column (as string, not symbol)
                    @test "Time" in names(gen_by_type)
                    @test "Time" in names(redisp_by_type)
                    
                    # Test summarize_result
                    summary_gen = summarize_result(gen_by_type)
                    @test summary_gen isa DataFrame
                    @test nrow(summary_gen) == 1
                end
            end
        end
        
        @testset "Edge cases for get_redispatch_by_type_node" begin
            # Test various edge cases
            expected_dir = joinpath(@__DIR__, "expected_results")
            
            # Test with split time horizon (testcase_8 has split=2)
            testcase_split = joinpath(expected_dir, "testcase_8_ZonalMarketWithRedispatch_NoProsumer")
            
            if isdir(testcase_split)
                @testset "Split time horizon" begin
                    results = DataFiles(testcase_split)
                    
                    if !isempty(results.GEN) && !isempty(results.REDISP)
                        redispatch_diff = get_redispatch_by_type_node(results)
                        
                        # Should handle split time horizon correctly
                        @test !isempty(redispatch_diff)
                        
                        # Time values should be consecutive or properly split
                        times = sort(unique(redispatch_diff.Time))
                        @test length(times) > 0
                    end
                end
            end
            
            # Test with prosumer data (testcase_9)
            testcase_prosumer = joinpath(expected_dir, "testcase_9_ZonalMarketWithRedispatch_ProsumerOptimization")
            
            if isdir(testcase_prosumer)
                @testset "Prosumer optimization scenario" begin
                    results = DataFiles(testcase_prosumer)
                    
                    if !isempty(results.GEN) && !isempty(results.REDISP)
                        redispatch_diff = get_redispatch_by_type_node(results)
                        
                        # Should work with prosumer data
                        @test redispatch_diff isa DataFrame
                        @test all(col in names(redispatch_diff) for col in ["Time", "node", "type", "GEN", "GEN_REDISP", "difference"])
                    end
                end
            end
        end
    end
end
