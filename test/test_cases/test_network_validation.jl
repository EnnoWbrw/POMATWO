using Test
using POMATWO

# Helper function to create test Parameters with network data
function create_test_params(;
    nodes=String[],
    lines=String[],
    zones=["zone1"],
    plants=["plant1"],
    line_start=Dict{String,String}(),
    line_end=Dict{String,String}(),
    reactance=Dict{String,Float64}(),
    resistance=Dict{String,Float64}(),
    slack=String[]
)
    sets = POMATWO.Sets(
        N=nodes,
        L=lines,
        Z=zones,
        P=plants,
        S=String[],
        DC=String[],
        DISP=String[],
        NDISP=String[],
        NTC=Tuple{String,String}[],
        PRS=String[],
        PRS_STO=String[]
    )
    
    return POMATWO.Parameters(
        sets=sets,
        line_start=line_start,
        line_end=line_end,
        reactance=reactance,
        resistance=resistance,
        slack=slack
    )
end

@testset "Network Topology Validation" begin
    
    @testset "Valid simple network" begin
        # Create a simple valid 3-node network
        params = create_test_params(
            nodes=["node1", "node2", "node3"],
            lines=["line1", "line2"],
            line_start=Dict("line1" => "node1", "line2" => "node2"),
            line_end=Dict("line1" => "node2", "line2" => "node3"),
            reactance=Dict("line1" => 0.1, "line2" => 0.15),
            resistance=Dict("line1" => 0.01, "line2" => 0.02),
            slack=["node1"]
        )
        
        report = POMATWO.validate_params(params)
        
        # Should have no errors
        @test !report.has_errors
        @test isempty(POMATWO.get_errors(report))
    end
    
    @testset "Isolated node detection" begin
        params = create_test_params(
            nodes=["node1", "node2", "node3", "node4"],
            lines=["line1"],
            line_start=Dict("line1" => "node1"),
            line_end=Dict("line1" => "node2"),
            reactance=Dict("line1" => 0.1),
            resistance=Dict("line1" => 0.01),
            slack=["node1"]
        )
        
        report = POMATWO.validate_params(params)
        
        @test report.has_errors
        errors = POMATWO.get_errors(report)
        
        # Should detect isolated nodes
        isolated_error = findfirst(e -> e.category == "network_topology" && 
                                       occursin("isolated", e.message), errors)
        @test isolated_error !== nothing
        @test occursin("node3", errors[isolated_error].message)
        @test occursin("node4", errors[isolated_error].message)
    end
    
    @testset "Network islands detection" begin
        # Create two separate islands
        params = create_test_params(
            nodes=["n1", "n2", "n3", "n4"],
            lines=["line1", "line2"],
            line_start=Dict("line1" => "n1", "line2" => "n3"),
            line_end=Dict("line1" => "n2", "line2" => "n4"),
            reactance=Dict("line1" => 0.1, "line2" => 0.1),
            resistance=Dict("line1" => 0.01, "line2" => 0.01),
            slack=["n1"]
        )
        
        report = POMATWO.validate_params(params)
        
        @test report.has_errors
        errors = POMATWO.get_errors(report)
        
        # Should detect 2 islands
        islands_error = findfirst(e -> e.category == "network_topology" && 
                                      occursin("disconnected islands", e.message), errors)
        @test islands_error !== nothing
        @test occursin("2 disconnected islands", errors[islands_error].message)
        
        # Should report each island
        island_reports = filter(e -> e.category == "network_topology" && 
                                    occursin("Island", e.message), errors)
        @test length(island_reports) >= 2
    end
    
    @testset "Zero reactance detection" begin
        params = create_test_params(
            nodes=["node1", "node2"],
            lines=["line1"],
            line_start=Dict("line1" => "node1"),
            line_end=Dict("line1" => "node2"),
            reactance=Dict("line1" => 0.0),  # Zero reactance!
            resistance=Dict("line1" => 0.01),
            slack=["node1"]
        )
        
        report = POMATWO.validate_params(params)
        
        @test report.has_errors
        errors = POMATWO.get_errors(report)
        
        # Should detect zero reactance
        zero_x_error = findfirst(e -> e.category == "network_topology" && 
                                     occursin("zero reactance", e.message), errors)
        @test zero_x_error !== nothing
        @test occursin("line1", errors[zero_x_error].message)
    end
    
    @testset "Very small reactance warning" begin
        params = create_test_params(
            nodes=["node1", "node2"],
            lines=["line1"],
            line_start=Dict("line1" => "node1"),
            line_end=Dict("line1" => "node2"),
            reactance=Dict("line1" => 1e-12),  # Very small
            resistance=Dict("line1" => 0.01),
            slack=["node1"]
        )
        
        report = POMATWO.validate_params(params)
        
        warnings = POMATWO.get_warnings(report)
        
        # Should warn about small reactance
        small_x_warning = findfirst(w -> w.category == "network_topology" && 
                                        occursin("very small reactance", w.message), warnings)
        @test small_x_warning !== nothing
    end
    
    @testset "Invalid node reference" begin
        params = create_test_params(
            nodes=["node1", "node2"],
            lines=["line1"],
            line_start=Dict("line1" => "node1"),
            line_end=Dict("line1" => "node_nonexistent"),  # Invalid node!
            reactance=Dict("line1" => 0.1),
            resistance=Dict("line1" => 0.01),
            slack=["node1"]
        )
        
        report = POMATWO.validate_params(params)
        
        @test report.has_errors
        errors = POMATWO.get_errors(report)
        
        # Should detect invalid node reference
        invalid_node_error = findfirst(e -> e.category == "network_topology" && 
                                           occursin("non-existent", e.message), errors)
        @test invalid_node_error !== nothing
        @test occursin("node_nonexistent", errors[invalid_node_error].message)
    end
    
    @testset "Self-loop detection" begin
        params = create_test_params(
            nodes=["node1", "node2"],
            lines=["line1"],
            line_start=Dict("line1" => "node1"),
            line_end=Dict("line1" => "node1"),  # Self-loop!
            reactance=Dict("line1" => 0.1),
            resistance=Dict("line1" => 0.01),
            slack=["node1"]
        )
        
        report = POMATWO.validate_params(params)
        
        @test report.has_errors
        errors = POMATWO.get_errors(report)
        
        # Should detect self-loop
        self_loop_error = findfirst(e -> e.category == "network_topology" && 
                                        occursin("connects node", e.message) &&
                                        occursin("to itself", e.message), errors)
        @test self_loop_error !== nothing
    end
    
    @testset "Parallel lines warning" begin
        # Both lines connect same nodes
        params = create_test_params(
            nodes=["node1", "node2"],
            lines=["line1", "line2"],
            line_start=Dict("line1" => "node1", "line2" => "node1"),
            line_end=Dict("line1" => "node2", "line2" => "node2"),
            reactance=Dict("line1" => 0.1, "line2" => 0.15),
            resistance=Dict("line1" => 0.01, "line2" => 0.02),
            slack=["node1"]
        )
        
        report = POMATWO.validate_params(params)

        notes = POMATWO.get_notes(report)

        # Should have a single note about parallel lines
        parallel_note = findfirst(n -> n.category == "network_topology" && 
                                      occursin("parallel line group", n.message), notes)
        @test parallel_note !== nothing
        @test occursin("line1", notes[parallel_note].message)
        @test occursin("line2", notes[parallel_note].message)
        @test occursin("node1", notes[parallel_note].message)
        @test occursin("node2", notes[parallel_note].message)
    end
    
    @testset "Disconnected slack bus" begin
        # Only node2 and node3 are connected
        params = create_test_params(
            nodes=["node1", "node2", "node3"],
            lines=["line1"],
            line_start=Dict("line1" => "node2"),
            line_end=Dict("line1" => "node3"),
            reactance=Dict("line1" => 0.1),
            resistance=Dict("line1" => 0.01),
            slack=["node1"]  # Slack bus not connected!
        )
        
        report = POMATWO.validate_params(params)
        
        @test report.has_errors
        errors = POMATWO.get_errors(report)
        
        # Should detect disconnected slack bus
        slack_error = findfirst(e -> e.category == "network_topology" && 
                                    occursin("Slack bus", e.message) &&
                                    occursin("not connected", e.message), errors)
        @test slack_error !== nothing
        @test occursin("node1", errors[slack_error].message)
    end
    
    @testset "No lines - copper plate mode" begin
        params = create_test_params(
            nodes=["node1", "node2"],
            lines=String[],  # No lines
            slack=["node1"]
        )
        
        report = POMATWO.validate_params(params)
        
        # Should not have errors (copper plate is valid)
        @test !report.has_errors
        
        notes = POMATWO.get_notes(report)
        
        # Should note copper plate mode
        copper_plate_note = findfirst(n -> occursin("copper plate", n.message), notes)
        @test copper_plate_note !== nothing
    end
    
    @testset "Missing slack bus" begin
        params = create_test_params(
            nodes=["node1", "node2"],
            lines=["line1"],
            line_start=Dict("line1" => "node1"),
            line_end=Dict("line1" => "node2"),
            reactance=Dict("line1" => 0.1),
            resistance=Dict("line1" => 0.01),
            slack=String[]  # No slack bus!
        )
        
        report = POMATWO.validate_params(params)
        
        @test report.has_errors
        errors = POMATWO.get_errors(report)
        
        # Should detect missing slack bus
        slack_error = findfirst(e -> e.category == "missing_data" && 
                                    occursin("slack bus", e.message), errors)
        @test slack_error !== nothing
    end
    
    @testset "Complex network with multiple issues" begin
        # Island 1: n1-n2 (with slack)
        # Island 2: n3-n4 (no slack)
        # n5 isolated
        # line3 has zero reactance
        params = create_test_params(
            nodes=["n1", "n2", "n3", "n4", "n5"],
            lines=["line1", "line2", "line3"],
            line_start=Dict("line1" => "n1", "line2" => "n3", "line3" => "n1"),
            line_end=Dict("line1" => "n2", "line2" => "n4", "line3" => "n2"),
            reactance=Dict("line1" => 0.1, "line2" => 0.1, "line3" => 0.0),
            resistance=Dict("line1" => 0.01, "line2" => 0.01, "line3" => 0.01),
            slack=["n1"]
        )
        
        report = POMATWO.validate_params(params)
        
        @test report.has_errors
        errors = POMATWO.get_errors(report)
        
        # Should detect zero reactance
        @test any(e -> e.category == "network_topology" && 
                      occursin("zero reactance", e.message), errors)
        
        # Should detect isolated node
        @test any(e -> e.category == "network_topology" && 
                      occursin("isolated", e.message), errors)
        
        # Should detect islands
        @test any(e -> e.category == "network_topology" && 
                      occursin("disconnected islands", e.message), errors)
    end
    
    @testset "Integration with load_data_with_report" begin
        # Use test data
        test_data_path = joinpath(@__DIR__, "..", "data", "test_data_3_nodes_prosumer")
        
        data = Dict(
            :plants => joinpath(test_data_path, "plants.csv"),
            :nodes => joinpath(test_data_path, "nodes.csv"),
            :zones => joinpath(test_data_path, "zones.csv"),
            :lines => joinpath(test_data_path, "lines.csv"),
            :demand => joinpath(test_data_path, "nodal_load.csv"),
            :types => joinpath(test_data_path, "planttypes.csv"),
        )
        
        params, report = POMATWO.load_data_with_report(data)
        
        # Test data should load without network topology errors
        # (assuming test data is valid)
        topology_errors = filter(e -> e.category == "network_topology", 
                                POMATWO.get_errors(report))
        
        # If there are topology errors in test data, that's a problem
        if !isempty(topology_errors)
            @warn "Test data has topology issues:" topology_errors
        end
    end
    
    @testset "Validate network_topology function directly" begin
        # Test the validation function directly
        params = create_test_params(
            nodes=["node1", "node2"],
            lines=["line1"],
            line_start=Dict("line1" => "node1"),
            line_end=Dict("line1" => "node2"),
            reactance=Dict("line1" => 0.1),
            resistance=Dict("line1" => 0.01),
            slack=["node1"]
        )
        
        report = POMATWO.DataReport()
        result = POMATWO.validate_network_topology(report, params, "test location")
        
        @test result == true  # Should return true for valid network
        @test !report.has_errors
    end
    
    @testset "Large network performance" begin
        # Test with a larger network to ensure performance is acceptable
        n_nodes = 100
        n_lines = 150
        
        # Create a connected network
        line_start = Dict{String,String}()
        line_end = Dict{String,String}()
        reactance = Dict{String,Float64}()
        resistance = Dict{String,Float64}()
        
        # Connect nodes sequentially first (ensure connectivity)
        for i in 1:(n_nodes-1)
            line = "line_$i"
            line_start[line] = "node_$i"
            line_end[line] = "node_$(i+1)"
            reactance[line] = 0.1 + 0.01 * i
            resistance[line] = 0.01 + 0.001 * i
        end
        
        # Add random extra lines
        for i in n_nodes:n_lines
            line = "line_$i"
            node1 = rand(1:n_nodes)
            node2 = rand(1:n_nodes)
            while node2 == node1
                node2 = rand(1:n_nodes)
            end
            line_start[line] = "node_$node1"
            line_end[line] = "node_$node2"
            reactance[line] = 0.1 + rand() * 0.2
            resistance[line] = 0.01 + rand() * 0.02
        end
        
        params = create_test_params(
            nodes=["node_$i" for i in 1:n_nodes],
            lines=["line_$i" for i in 1:n_lines],
            line_start=line_start,
            line_end=line_end,
            reactance=reactance,
            resistance=resistance,
            slack=["node_1"]
        )
        
        # Time the validation
        t_start = time()
        report = POMATWO.validate_params(params)
        t_elapsed = time() - t_start
        
        # Should complete in reasonable time (< 5 seconds for 100 nodes)
        @test t_elapsed < 5.0
        
        # Should not have errors (network is connected)
        @test !report.has_errors
        
        println("Large network validation took $(round(t_elapsed, digits=3)) seconds")
    end
end
