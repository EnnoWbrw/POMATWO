"""
Test suite for data load validations including:
- Time horizon length checks (row count vs TimeHorizon.stop)
- Node consistency checks for demand and availability
- Validation error/warning reporting
"""

@testset "Data Load Validations" begin
    
    @testset "Time Horizon Length - Demand Validation" begin
        # Create params with correct length demand (4 timesteps)
        params_correct = create_test_params(
            nodes=["n1", "n2"],
            slack=["n1"]
        )
        params_correct.nodal_load["n1"] = POMATWO.HourlyProfile([10.0, 20.0, 30.0, 40.0])
        params_correct.nodal_load["n2"] = POMATWO.HourlyProfile([15.0, 25.0, 35.0, 45.0])
        
        setup_correct = ModelSetup(TimeHorizon=TimeHorizon(start=1, stop=4, split=2, offset=0))
        report_correct = POMATWO.validate_params(params_correct, setup_correct)
        
        # Should have no errors for correct length
        @test !report_correct.has_errors
        
        # Create params with wrong length demand (3 timesteps vs stop=4)
        params_wrong = create_test_params(
            nodes=["n1", "n2"],
            slack=["n1"]
        )
        params_wrong.nodal_load["n1"] = POMATWO.HourlyProfile([10.0, 20.0, 30.0])
        params_wrong.nodal_load["n2"] = POMATWO.HourlyProfile([15.0, 25.0, 35.0])
        
        setup_wrong = ModelSetup(TimeHorizon=TimeHorizon(start=1, stop=4, split=2, offset=0))
        report_wrong = POMATWO.validate_params(params_wrong, setup_wrong)
        
        # Should have errors for length mismatch
        @test report_wrong.has_errors
        errors = POMATWO.get_errors(report_wrong)
        @test any(e -> occursin("timeseries_length_mismatch", e.category), errors)
        @test any(e -> occursin("length 3 but TimeHorizon.stop=4", e.message), errors)
    end
    
    @testset "Time Horizon Length - Availability Validation" begin
        # Create params with correct length availability
        params_correct = create_test_params(
            nodes=["n1"],
            plants=["p1"],
            slack=["n1"]
        )
        params_correct.nodal_load["n1"] = POMATWO.HourlyProfile([10.0, 20.0, 30.0, 40.0])
        params_correct.avail["p1"] = POMATWO.HourlyProfile([0.9, 0.8, 0.95, 0.85])
        
        setup = ModelSetup(TimeHorizon=TimeHorizon(start=1, stop=4, split=2, offset=0))
        report_correct = POMATWO.validate_params(params_correct, setup)
        
        # Should have no errors
        @test !report_correct.has_errors
        
        # Create params with wrong length availability (3 vs 4)
        params_wrong = create_test_params(
            nodes=["n1"],
            plants=["p1"],
            slack=["n1"]
        )
        params_wrong.nodal_load["n1"] = POMATWO.HourlyProfile([10.0, 20.0, 30.0, 40.0])
        params_wrong.avail["p1"] = POMATWO.HourlyProfile([0.9, 0.8, 0.95])
        
        report_wrong = POMATWO.validate_params(params_wrong, setup)
        
        # Should have error for availability length mismatch
        @test report_wrong.has_errors
        errors = POMATWO.get_errors(report_wrong)
        @test any(e -> occursin("timeseries_length_mismatch", e.category) && occursin("p1", e.message), errors)
    end
    
    @testset "Time Horizon Length - Inflow Validation" begin
        # Create params with correct length inflow
        params_correct = create_test_params(
            nodes=["n1"],
            plants=["s1"],
            slack=["n1"]
        )
        params_correct.nodal_load["n1"] = POMATWO.HourlyProfile([10.0, 20.0, 30.0, 40.0])
        params_correct.inflow["s1"] = POMATWO.HourlyProfile([5.0, 10.0, 8.0, 12.0])
        
        setup = ModelSetup(TimeHorizon=TimeHorizon(start=1, stop=4, split=2, offset=0))
        report_correct = POMATWO.validate_params(params_correct, setup)
        
        # Should have no errors
        @test !report_correct.has_errors
        
        # Create params with wrong length inflow (5 vs 4)
        params_wrong = create_test_params(
            nodes=["n1"],
            plants=["s1"],
            slack=["n1"]
        )
        params_wrong.nodal_load["n1"] = POMATWO.HourlyProfile([10.0, 20.0, 30.0, 40.0])
        params_wrong.inflow["s1"] = POMATWO.HourlyProfile([5.0, 10.0, 8.0, 12.0, 7.0])
        
        report_wrong = POMATWO.validate_params(params_wrong, setup)
        
        # Should have error for inflow length mismatch
        @test report_wrong.has_errors
        errors = POMATWO.get_errors(report_wrong)
        @test any(e -> occursin("timeseries_length_mismatch", e.category) && occursin("s1", e.message), errors)
    end
    
    @testset "FixedProfile Does Not Error" begin
        # Create params with FixedProfile (constant value)
        params = create_test_params(
            nodes=["n1"],
            plants=["p1"],
            slack=["n1"]
        )
        params.nodal_load["n1"] = POMATWO.HourlyProfile([10.0, 20.0, 30.0, 40.0])
        params.avail["p1"] = POMATWO.FixedProfile(1.0)  # Constant availability
        
        setup = ModelSetup(TimeHorizon=TimeHorizon(start=1, stop=4, split=2, offset=0))
        report = POMATWO.validate_params(params, setup)
        
        # FixedProfile should not trigger length errors
        errors = POMATWO.get_errors(report)
        @test !any(e -> occursin("p1", e.message) && occursin("timeseries_length", e.category), errors)
    end
    
    @testset "Multiple Length Errors Reported" begin
        # Create params with multiple length mismatches
        params = create_test_params(
            nodes=["n1", "n2"],
            plants=["p1", "p2"],
            slack=["n1"]
        )
        # Demand with wrong length (3 vs 4)
        params.nodal_load["n1"] = POMATWO.HourlyProfile([10.0, 20.0, 30.0])
        params.nodal_load["n2"] = POMATWO.HourlyProfile([15.0, 25.0, 35.0])
        # Availability with wrong length (2 vs 4)
        params.avail["p1"] = POMATWO.HourlyProfile([0.9, 0.8])
        params.avail["p2"] = POMATWO.HourlyProfile([0.85, 0.95])
        
        setup = ModelSetup(TimeHorizon=TimeHorizon(start=1, stop=4, split=2, offset=0))
        report = POMATWO.validate_params(params, setup)
        
        # Should report multiple errors (2 nodes + 2 plants = 4 errors)
        @test report.has_errors
        errors = POMATWO.get_errors(report)
        length_errors = filter(e -> occursin("timeseries_length_mismatch", e.category), errors)
        @test length(length_errors) >= 4
    end
    
    @testset "Node Consistency - Demand Validation" begin
        # Create params with demand for node that doesn't exist
        params = create_test_params(
            nodes=["n1", "n2"],
            slack=["n1"]
        )
        params.nodal_load["n1"] = POMATWO.HourlyProfile([10.0, 20.0])
        params.nodal_load["n2"] = POMATWO.HourlyProfile([15.0, 25.0])
        params.nodal_load["n999"] = POMATWO.HourlyProfile([5.0, 10.0])  # Unknown node
        
        setup = ModelSetup(TimeHorizon=TimeHorizon(start=1, stop=2, split=2, offset=0))
        report = POMATWO.validate_params(params, setup)
        
        # Should have error for unknown node
        @test report.has_errors
        errors = POMATWO.get_errors(report)
        @test any(e -> occursin("unknown_node_in_demand", e.category) && occursin("n999", e.message), errors)
    end
    
    @testset "Node Consistency - Missing Demand Warning" begin
        # Create params where a node has no demand entry
        params = create_test_params(
            nodes=["n1", "n2", "n3"],
            slack=["n1"]
        )
        params.nodal_load["n1"] = POMATWO.HourlyProfile([10.0, 20.0])
        params.nodal_load["n2"] = POMATWO.HourlyProfile([15.0, 25.0])
        # n3 has no demand entry
        
        setup = ModelSetup(TimeHorizon=TimeHorizon(start=1, stop=2, split=2, offset=0))
        report = POMATWO.validate_params(params, setup)
        
    # Should have warning for missing demand
    warnings = POMATWO.get_warnings(report)
    @test !isempty(warnings)
        @test any(w -> occursin("node_missing_demand", w.category) && occursin("n3", w.message), warnings)
    end
    
    @testset "Node Consistency - Nodal Availability Validation" begin
        # Create params with nodal availability for unknown node
        params = create_test_params(
            nodes=["n1", "n2"],
            slack=["n1"]
        )
        params.nodal_load["n1"] = POMATWO.HourlyProfile([10.0, 20.0])
        params.nodal_load["n2"] = POMATWO.HourlyProfile([15.0, 25.0])
        params.avail_planttype_nodal[("wind", "n1")] = POMATWO.HourlyProfile([0.9, 0.8])
        params.avail_planttype_nodal[("wind", "n999")] = POMATWO.HourlyProfile([0.7, 0.6])  # Unknown node
        
        setup = ModelSetup(TimeHorizon=TimeHorizon(start=1, stop=2, split=2, offset=0))
        report = POMATWO.validate_params(params, setup)
        
        # Should have error for unknown node in availability
        @test report.has_errors
        errors = POMATWO.get_errors(report)
        @test any(e -> occursin("unknown_node_in_availability", e.category) && occursin("n999", e.message), errors)
        
    # Should have warning for node without availability
    warnings = POMATWO.get_warnings(report)
    @test !isempty(warnings)
        @test any(w -> occursin("node_missing_availability", w.category) && occursin("n2", w.message), warnings)
    end
    
    @testset "Base Validation Still Works" begin
        # Test that validate_params(params) without setup still works
        params = create_test_params(
            nodes=["n1"],
            slack=["n1"]
        )
        params.nodal_load["n1"] = POMATWO.HourlyProfile([10.0, 20.0, 30.0])
        
        report = POMATWO.validate_params(params)  # Without setup
        
        # Should complete without errors (no time horizon check)
        @test !report.has_errors
    end
    
    @testset "Empty Nodal Availability Produces Note" begin
        # Test when no nodal availability data is present
        params = create_test_params(
            nodes=["n1"],
            slack=["n1"]
        )
        params.nodal_load["n1"] = POMATWO.HourlyProfile([10.0, 20.0])
        # No nodal availability data
        
        setup = ModelSetup(TimeHorizon=TimeHorizon(start=1, stop=2, split=2, offset=0))
        report = POMATWO.validate_params(params, setup)
        
        # Should have note about absent nodal availability
        notes = POMATWO.get_notes(report)
        @test any(n -> occursin("nodal_availability_absent", n.category), notes)
    end
    
    @testset "Combined Validations" begin
        # Test multiple validation issues together
        params = create_test_params(
            nodes=["n1", "n2"],
            plants=["p1", "p2"],
            slack=["n1"]
        )
        # Demand: wrong length and unknown node
        params.nodal_load["n1"] = POMATWO.HourlyProfile([10.0, 20.0, 30.0])  # length 3 vs 4
        params.nodal_load["n999"] = POMATWO.HourlyProfile([5.0, 10.0, 15.0, 20.0])  # unknown node
        # Availability: wrong length
        params.avail["p1"] = POMATWO.HourlyProfile([0.9, 0.8])  # length 2 vs 4
        params.avail["p2"] = POMATWO.FixedProfile(1.0)  # OK
        # Nodal availability: unknown node
        params.avail_planttype_nodal[("wind", "n888")] = POMATWO.HourlyProfile([0.7, 0.8, 0.9, 0.85])
        
        setup = ModelSetup(TimeHorizon=TimeHorizon(start=1, stop=4, split=2, offset=0))
        report = POMATWO.validate_params(params, setup)
        
        # Should have multiple errors
        @test report.has_errors
        errors = POMATWO.get_errors(report)
        
        # Check for different error types
        @test any(e -> occursin("timeseries_length_mismatch", e.category), errors)
        @test any(e -> occursin("unknown_node_in_demand", e.category), errors)
        @test any(e -> occursin("unknown_node_in_availability", e.category), errors)
        
    # Should also have warnings
    warnings = POMATWO.get_warnings(report)
    @test !isempty(warnings)
        @test any(w -> occursin("node_missing_demand", w.category) && occursin("n2", w.message), warnings)
    end
end
