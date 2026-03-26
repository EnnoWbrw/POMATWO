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
        
        # Create params with too short demand (3 timesteps vs stop=4)
        params_short = create_test_params(
            nodes=["n1", "n2"],
            slack=["n1"]
        )
        params_short.nodal_load["n1"] = POMATWO.HourlyProfile([10.0, 20.0, 30.0])
        params_short.nodal_load["n2"] = POMATWO.HourlyProfile([15.0, 25.0, 35.0])
        
        setup_short = ModelSetup(TimeHorizon=TimeHorizon(start=1, stop=4, split=2, offset=0))
        report_short = POMATWO.validate_params(params_short, setup_short)
        
        # Should have errors for length too short
        @test report_short.has_errors
        errors = POMATWO.get_errors(report_short)
        @test any(e -> occursin("timeseries_length_mismatch", e.category), errors)
        @test any(e -> occursin("length 3 but TimeHorizon.stop=4", e.message), errors)
        
        # Create params with too long demand (5 timesteps vs stop=4)
        params_long = create_test_params(
            nodes=["n1", "n2"],
            slack=["n1"]
        )
        params_long.nodal_load["n1"] = POMATWO.HourlyProfile([10.0, 20.0, 30.0, 40.0, 50.0])
        params_long.nodal_load["n2"] = POMATWO.HourlyProfile([15.0, 25.0, 35.0, 45.0, 55.0])
        
        setup_long = ModelSetup(TimeHorizon=TimeHorizon(start=1, stop=4, split=2, offset=0))
        report_long = POMATWO.validate_params(params_long, setup_long)
        
        # Should have warnings (not errors) for excess length
        @test !report_long.has_errors
        warnings = POMATWO.get_warnings(report_long)
        @test !isempty(warnings)
        @test any(w -> occursin("timeseries_length_excess", w.category), warnings)
        @test any(w -> occursin("length 5 exceeding TimeHorizon.stop=4", w.message), warnings)
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
        
        # Create params with too short availability (3 vs 4)
        params_short = create_test_params(
            nodes=["n1"],
            plants=["p1"],
            slack=["n1"]
        )
        params_short.nodal_load["n1"] = POMATWO.HourlyProfile([10.0, 20.0, 30.0, 40.0])
        params_short.avail["p1"] = POMATWO.HourlyProfile([0.9, 0.8, 0.95])
        
        report_short = POMATWO.validate_params(params_short, setup)
        
        # Should have error for availability length too short
        @test report_short.has_errors
        errors = POMATWO.get_errors(report_short)
        @test any(e -> occursin("timeseries_length_mismatch", e.category) && occursin("p1", e.message), errors)
        
        # Create params with too long availability (5 vs 4)
        params_long = create_test_params(
            nodes=["n1"],
            plants=["p1"],
            slack=["n1"]
        )
        params_long.nodal_load["n1"] = POMATWO.HourlyProfile([10.0, 20.0, 30.0, 40.0])
        params_long.avail["p1"] = POMATWO.HourlyProfile([0.9, 0.8, 0.95, 0.85, 0.92])
        
        report_long = POMATWO.validate_params(params_long, setup)
        
        # Should have warning (not error) for excess length
        @test !report_long.has_errors
        warnings = POMATWO.get_warnings(report_long)
        @test !isempty(warnings)
        @test any(w -> occursin("timeseries_length_excess", w.category) && occursin("p1", w.message), warnings)
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
        
        # Create params with too short inflow (3 vs 4)
        params_short = create_test_params(
            nodes=["n1"],
            plants=["s1"],
            slack=["n1"]
        )
        params_short.nodal_load["n1"] = POMATWO.HourlyProfile([10.0, 20.0, 30.0, 40.0])
        params_short.inflow["s1"] = POMATWO.HourlyProfile([5.0, 10.0, 8.0])
        
        report_short = POMATWO.validate_params(params_short, setup)
        
        # Should have error for inflow length too short
        @test report_short.has_errors
        errors = POMATWO.get_errors(report_short)
        @test any(e -> occursin("timeseries_length_mismatch", e.category) && occursin("s1", e.message), errors)
        
        # Create params with too long inflow (5 vs 4)
        params_long = create_test_params(
            nodes=["n1"],
            plants=["s1"],
            slack=["n1"]
        )
        params_long.nodal_load["n1"] = POMATWO.HourlyProfile([10.0, 20.0, 30.0, 40.0])
        params_long.inflow["s1"] = POMATWO.HourlyProfile([5.0, 10.0, 8.0, 12.0, 7.0])
        
        report_long = POMATWO.validate_params(params_long, setup)
        
        # Should have warning (not error) for excess length
        @test !report_long.has_errors
        warnings = POMATWO.get_warnings(report_long)
        @test !isempty(warnings)
        @test any(w -> occursin("timeseries_length_excess", w.category) && occursin("s1", w.message), warnings)
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
        # Create params with multiple length mismatches (too short)
        params = create_test_params(
            nodes=["n1", "n2"],
            plants=["p1", "p2"],
            slack=["n1"]
        )
        # Demand with wrong length (3 vs 4) - too short = error
        params.nodal_load["n1"] = POMATWO.HourlyProfile([10.0, 20.0, 30.0])
        params.nodal_load["n2"] = POMATWO.HourlyProfile([15.0, 25.0, 35.0])
        # Availability with wrong length (2 vs 4) - too short = error
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
    
    @testset "Mixed Length Issues - Errors and Warnings" begin
        # Test with both too short (error) and too long (warning) data
        params = create_test_params(
            nodes=["n1", "n2"],
            plants=["p1", "p2"],
            slack=["n1"]
        )
        # n1 demand too short (error)
        params.nodal_load["n1"] = POMATWO.HourlyProfile([10.0, 20.0])
        # n2 demand too long (warning)
        params.nodal_load["n2"] = POMATWO.HourlyProfile([15.0, 25.0, 35.0, 45.0, 55.0])
        # p1 availability too short (error)
        params.avail["p1"] = POMATWO.HourlyProfile([0.9])
        # p2 availability too long (warning)
        params.avail["p2"] = POMATWO.HourlyProfile([0.85, 0.95, 0.90, 0.88, 0.92, 0.87])
        
        setup = ModelSetup(TimeHorizon=TimeHorizon(start=1, stop=4, split=2, offset=0))
        report = POMATWO.validate_params(params, setup)
        
        # Should have errors for too-short data
        @test report.has_errors
        errors = POMATWO.get_errors(report)
        short_errors = filter(e -> occursin("timeseries_length_mismatch", e.category), errors)
        @test length(short_errors) == 2  # n1 and p1
        @test any(e -> occursin("n1", e.message) && occursin("length 2", e.message), errors)
        @test any(e -> occursin("p1", e.message) && occursin("length 1", e.message), errors)
        
        # Should have warnings for too-long data
        warnings = POMATWO.get_warnings(report)
        @test !isempty(warnings)
        excess_warnings = filter(w -> occursin("timeseries_length_excess", w.category), warnings)
        @test length(excess_warnings) == 2  # n2 and p2
        @test any(w -> occursin("n2", w.message) && occursin("length 5", w.message), warnings)
        @test any(w -> occursin("p2", w.message) && occursin("length 6", w.message), warnings)
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
        # Demand: too short and unknown node
        params.nodal_load["n1"] = POMATWO.HourlyProfile([10.0, 20.0, 30.0])  # length 3 vs 4 - error
        params.nodal_load["n999"] = POMATWO.HourlyProfile([5.0, 10.0, 15.0, 20.0])  # unknown node - error
        # Availability: too short
        params.avail["p1"] = POMATWO.HourlyProfile([0.9, 0.8])  # length 2 vs 4 - error
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
    
    @testset "Excess Data Across All Types" begin
        # Test that excess data in all timeseries types generates warnings, not errors
        params = create_test_params(
            nodes=["n1"],
            plants=["p1", "s1"],
            slack=["n1"]
        )
        # All have excess data (length 6 vs stop=4)
        params.nodal_load["n1"] = POMATWO.HourlyProfile([10.0, 20.0, 30.0, 40.0, 50.0, 60.0])
        params.avail["p1"] = POMATWO.HourlyProfile([0.9, 0.8, 0.95, 0.85, 0.92, 0.88])
        params.inflow["s1"] = POMATWO.HourlyProfile([5.0, 10.0, 8.0, 12.0, 7.0, 9.0])
        
        setup = ModelSetup(TimeHorizon=TimeHorizon(start=1, stop=4, split=2, offset=0))
        report = POMATWO.validate_params(params, setup)
        
        # Should have NO errors (excess is just a warning)
        @test !report.has_errors
        
        # Should have warnings for all three
        warnings = POMATWO.get_warnings(report)
        @test !isempty(warnings)
        excess_warnings = filter(w -> occursin("timeseries_length_excess", w.category), warnings)
        @test length(excess_warnings) == 3  # n1 demand, p1 avail, s1 inflow
        @test any(w -> occursin("n1", w.message) && occursin("exceeding", w.message), warnings)
        @test any(w -> occursin("p1", w.message) && occursin("exceeding", w.message), warnings)
        @test any(w -> occursin("s1", w.message) && occursin("exceeding", w.message), warnings)
    end
end
