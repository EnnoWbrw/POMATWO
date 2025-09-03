function test_data_reporting()
@testset "Data Reporting System Tests" begin    
    @testset "DataReport Basic Functionality" begin
        report = DataReport()
        
        @test length(report.items) == 0
        @test !report.has_errors
        
        # Test adding different types of reports
        POMATWO.add_note!(report, "test", "This is a note", "test_location")
        @test length(report.items) == 1
      
        @test !report.has_errors

        POMATWO.add_warning!(report, "test", "This is a warning", "test_location")
        @test length(report.items) == 2
        @test !report.has_errors

        POMATWO.add_error!(report, "test", "This is an error", "test_location")
        @test length(report.items) == 3
        @test report.has_errors
        
        # Test filtering functions
        @test length(get_notes(report)) == 1
        @test length(get_warnings(report)) == 1
        @test length(get_errors(report)) == 1
    end
    
    @testset "Validation Functions" begin
        report = DataReport()
        
        # Test file validation
        @test !POMATWO.validate_file_exists(report, "nonexistent_file.csv", "test file")
        @test report.has_errors
        
        # Reset report
        report = DataReport()
        
        # Test with existing file
        test_file = joinpath("examples", "test_data_3_nodes", "plants.csv")
        if isfile(test_file)
            @test POMATWO.validate_file_exists(report, test_file, "test file")
            @test !report.has_errors
        end
        
        # Test column validation
        report = DataReport()
        test_df = DataFrame(
            index = ["p1", "p2"],
            g_max = [100.0, 200.0],
            eta = [0.8, 1.2],  # One invalid efficiency
            bad_data = ["text", "more_text"]  # Non-numeric data
        )
        
        # Test required columns validation
        @test POMATWO.validate_required_columns(report, test_df, [:index, :g_max], "test")
        @test !POMATWO.validate_required_columns(report, test_df, [:index, :missing_col], "test")

        # Reset report for numeric validation
        report = DataReport()
        
        # Test numeric column validation
        @test POMATWO.validate_numeric_column(report, test_df, :g_max, "test"; positive=true)
        @test !POMATWO.validate_numeric_column(report, test_df, :bad_data, "test")
    end
    
    @testset "Plants Data Validation" begin
        report = DataReport()
        params = POMATWO.Parameters()
        
        # Test with valid data
        valid_plants = DataFrame(
            index = ["p1", "p2", "p3"],
            plant_type = ["wind", "coal", "gas"],
            node = ["n1", "n2", "n3"],
            g_max = [100.0, 200.0, 150.0],
            eta = [1.0, 0.4, 0.6],
            storage_capacity = [missing, missing, missing],
            storage_power = [missing, missing, missing]
        )
        
        POMATWO.add_plants!(params, valid_plants, report, "test_plants")
        @test length(params.sets.P) == 3
        @test !report.has_errors
        
        # Test with invalid data
        report = DataReport()
        params = POMATWO.Parameters()
        
        invalid_plants = DataFrame(
            index = ["p1", "p2", "p1"],  # Duplicate index
            plant_type = ["wind", "coal", "gas"],
            node = ["n1", "n2", "n3"],
            g_max = [100.0, -50.0, 150.0],  # Negative capacity
            eta = [1.0, 0.4, 1.5]  # Efficiency > 1
        )

        POMATWO.add_plants!(params, invalid_plants, report, "test_plants")
        @test report.has_errors  # Should have errors for negative capacity and duplicates
        @test length(get_errors(report)) >= 1
    end
    
    @testset "Integration Test with Sample Data" begin
        # Test with the existing sample data
        datapath = joinpath(@__DIR__, "data", "test_data_3_nodes_prosumer")
        
        if isdir(datapath)
            data_files = Dict{Symbol,String}(
                :plants => joinpath(datapath, "plants.csv"),
                :nodes => joinpath(datapath, "nodes.csv"),
                :zones => joinpath(datapath, "zones.csv"),
                :lines => joinpath(datapath, "lines.csv"),
                :dclines => joinpath(datapath, "dclines.csv"),
                :demand => joinpath(datapath, "nodal_load.csv"),
                :types => joinpath(datapath, "planttypes.csv"),
            )
            
            # Test new reporting function
            params, report = load_data_with_report(data_files)
            
            @test !report.has_errors
            @test length(params.sets.P) > 0
            @test length(params.sets.N) > 0
            @test length(params.sets.Z) > 0
            
        else
            @warn "Sample data not found, skipping integration test"
        end
    end
    
    @testset "Error Handling" begin
        # Test with missing required files
        bad_data_files = Dict{Symbol,String}(
            :plants => "nonexistent_plants.csv",
            :nodes => "nonexistent_nodes.csv", 
            :zones => "nonexistent_zones.csv",
            :demand => "nonexistent_demand.csv",
            :types => "nonexistent_types.csv"
        )
        
        params, report = load_data_with_report(bad_data_files)
        @test report.has_errors
        @test length(get_errors(report)) > 0
        
        # Test that load_data throws an error with bad data
        @test_throws ErrorException load_data(bad_data_files)
    end
end

end