using Test
using POMATWO

# Helper function to create test Parameters with network data
function create_test_params_ptdf(;
    nodes=String[],
    lines=String[],
    dc_lines=String[],
    zones=["zone1"],
    plants=["plant1"],
    line_start=Dict{String,String}(),
    line_end=Dict{String,String}(),
    dc_start=Dict{String,String}(),
    dc_end=Dict{String,String}(),
    reactance=Dict{String,Float64}(),
    resistance=Dict{String,Float64}(),
    slack=String[]
)
    sets = POMATWO.Sets(
        N=nodes,
        L=lines,
        DC=dc_lines,
        Z=zones,
        P=plants,
        S=String[],
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
        dc_start=dc_start,
        dc_end=dc_end,
        reactance=reactance,
        resistance=resistance,
        slack=slack
    )
end

@testset "PTDF Node Omission Tests" begin
    
    @testset "get_nodes_to_omit_for_ptdf - No omissions" begin
        # Network with all nodes connected via AC lines
        params = create_test_params_ptdf(
            nodes=["node1", "node2", "node3"],
            lines=["line1", "line2"],
            line_start=Dict("line1" => "node1", "line2" => "node2"),
            line_end=Dict("line1" => "node2", "line2" => "node3"),
            reactance=Dict("line1" => 0.1, "line2" => 0.15),
            resistance=Dict("line1" => 0.01, "line2" => 0.02),
            slack=["node1"]
        )
        
        omit_list = POMATWO.get_nodes_to_omit_for_ptdf(params)
        @test isempty(omit_list)
    end
    
    @testset "get_nodes_to_omit_for_ptdf - Isolated node" begin
        # Network with one isolated node
        params = create_test_params_ptdf(
            nodes=["node1", "node2", "node3"],
            lines=["line1"],
            line_start=Dict("line1" => "node1"),
            line_end=Dict("line1" => "node2"),
            reactance=Dict("line1" => 0.1),
            resistance=Dict("line1" => 0.01),
            slack=["node1"]
        )
        
        omit_list = POMATWO.get_nodes_to_omit_for_ptdf(params)
        @test "node3" in omit_list
        @test length(omit_list) == 1
    end
    
    @testset "get_nodes_to_omit_for_ptdf - DC-only node" begin
        # Network with node connected only via DC line
        params = create_test_params_ptdf(
            nodes=["node1", "node2", "node3"],
            lines=["line1"],
            dc_lines=["dc1"],
            line_start=Dict("line1" => "node1"),
            line_end=Dict("line1" => "node2"),
            dc_start=Dict("dc1" => "node2"),
            dc_end=Dict("dc1" => "node3"),
            reactance=Dict("line1" => 0.1),
            resistance=Dict("line1" => 0.01),
            slack=["node1"]
        )
        
        omit_list = POMATWO.get_nodes_to_omit_for_ptdf(params)
        @test "node3" in omit_list
        @test length(omit_list) == 1
    end
    
    @testset "get_nodes_to_omit_for_ptdf - Multiple DC-only nodes" begin
        # Network with multiple DC-only connected nodes
        params = create_test_params_ptdf(
            nodes=["node1", "node2", "node3", "node4"],
            lines=["line1"],
            dc_lines=["dc1", "dc2"],
            line_start=Dict("line1" => "node1"),
            line_end=Dict("line1" => "node2"),
            dc_start=Dict("dc1" => "node2", "dc2" => "node3"),
            dc_end=Dict("dc1" => "node3", "dc2" => "node4"),
            reactance=Dict("line1" => 0.1),
            resistance=Dict("line1" => 0.01),
            slack=["node1"]
        )
        
        omit_list = POMATWO.get_nodes_to_omit_for_ptdf(params)
        @test "node3" in omit_list
        @test "node4" in omit_list
        @test length(omit_list) == 2
    end
    
    @testset "get_nodes_to_omit_for_ptdf - Mixed AC and DC connections" begin
        # Node connected via both AC and DC should NOT be omitted
        params = create_test_params_ptdf(
            nodes=["node1", "node2", "node3"],
            lines=["line1", "line2"],
            dc_lines=["dc1"],
            line_start=Dict("line1" => "node1", "line2" => "node2"),
            line_end=Dict("line1" => "node2", "line2" => "node3"),
            dc_start=Dict("dc1" => "node1"),
            dc_end=Dict("dc1" => "node3"),
            reactance=Dict("line1" => 0.1, "line2" => 0.15),
            resistance=Dict("line1" => 0.01, "line2" => 0.02),
            slack=["node1"]
        )
        
        omit_list = POMATWO.get_nodes_to_omit_for_ptdf(params)
        @test isempty(omit_list)  # node3 has AC connection, should not be omitted
    end
    
    @testset "get_nodes_to_omit_for_ptdf - Combined isolated and DC-only" begin
        # Network with both isolated and DC-only nodes
        params = create_test_params_ptdf(
            nodes=["node1", "node2", "node3", "node4"],
            lines=["line1"],
            dc_lines=["dc1"],
            line_start=Dict("line1" => "node1"),
            line_end=Dict("line1" => "node2"),
            dc_start=Dict("dc1" => "node2"),
            dc_end=Dict("dc1" => "node3"),
            reactance=Dict("line1" => 0.1),
            resistance=Dict("line1" => 0.01),
            slack=["node1"]
        )
        
        omit_list = POMATWO.get_nodes_to_omit_for_ptdf(params)
        @test "node3" in omit_list  # DC-only
        @test "node4" in omit_list  # Isolated
        @test length(omit_list) == 2
    end
    
    @testset "get_connected_nodes - Detailed connectivity info" begin
        # Test the underlying get_connected_nodes function
        params = create_test_params_ptdf(
            nodes=["node1", "node2", "node3", "node4"],
            lines=["line1"],
            dc_lines=["dc1"],
            line_start=Dict("line1" => "node1"),
            line_end=Dict("line1" => "node2"),
            dc_start=Dict("dc1" => "node2"),
            dc_end=Dict("dc1" => "node3"),
            reactance=Dict("line1" => 0.1),
            resistance=Dict("line1" => 0.01),
            slack=["node1"]
        )
        
        ac_conn, dc_conn, all_conn, dc_only, isolated = POMATWO.get_connected_nodes(params)
        
        @test "node1" in ac_conn
        @test "node2" in ac_conn
        @test !("node3" in ac_conn)
        @test !("node4" in ac_conn)
        
        @test "node2" in dc_conn
        @test "node3" in dc_conn
        @test !("node1" in dc_conn)
        @test !("node4" in dc_conn)
        
        @test "node1" in all_conn
        @test "node2" in all_conn
        @test "node3" in all_conn
        @test !("node4" in all_conn)
        
        @test "node3" in dc_only
        @test !("node2" in dc_only)
        
        @test "node4" in isolated
        @test length(isolated) == 1
    end
    
    @testset "build_adjacency_list - AC only" begin
        params = create_test_params_ptdf(
            nodes=["node1", "node2", "node3"],
            lines=["line1", "line2"],
            dc_lines=["dc1"],
            line_start=Dict("line1" => "node1", "line2" => "node2"),
            line_end=Dict("line1" => "node2", "line2" => "node3"),
            dc_start=Dict("dc1" => "node1"),
            dc_end=Dict("dc1" => "node3"),
            reactance=Dict("line1" => 0.1, "line2" => 0.15),
            resistance=Dict("line1" => 0.01, "line2" => 0.02),
            slack=["node1"]
        )
        
        adjacency, nodes = POMATWO.build_adjacency_list(params, false)
        
        @test length(nodes) == 3  # All nodes connected via AC
        @test haskey(adjacency, "node1")
        @test "node2" in adjacency["node1"]
        @test "node3" in adjacency["node2"]
        # DC connection should not appear
        @test !("node3" in adjacency["node1"])
    end
    
    @testset "build_adjacency_list - AC + DC" begin
        params = create_test_params_ptdf(
            nodes=["node1", "node2", "node3"],
            lines=["line1"],
            dc_lines=["dc1"],
            line_start=Dict("line1" => "node1"),
            line_end=Dict("line1" => "node2"),
            dc_start=Dict("dc1" => "node2"),
            dc_end=Dict("dc1" => "node3"),
            reactance=Dict("line1" => 0.1),
            resistance=Dict("line1" => 0.01),
            slack=["node1"]
        )
        
        adjacency, nodes = POMATWO.build_adjacency_list(params, true)
        
        @test length(nodes) == 3  # All nodes connected
        @test haskey(adjacency, "node2")
        @test "node1" in adjacency["node2"]
        @test "node3" in adjacency["node2"]  # DC connection included
    end
    
    @testset "find_network_islands - Single island" begin
        params = create_test_params_ptdf(
            nodes=["node1", "node2", "node3"],
            lines=["line1", "line2"],
            line_start=Dict("line1" => "node1", "line2" => "node2"),
            line_end=Dict("line1" => "node2", "line2" => "node3"),
            reactance=Dict("line1" => 0.1, "line2" => 0.15),
            resistance=Dict("line1" => 0.01, "line2" => 0.02),
            slack=["node1"]
        )
        
        adjacency, nodes = POMATWO.build_adjacency_list(params, true)
        islands = POMATWO.find_network_islands(adjacency, nodes)
        
        @test length(islands) == 1
        @test length(islands[1]) == 3
    end
    
    @testset "find_network_islands - Multiple islands" begin
        params = create_test_params_ptdf(
            nodes=["node1", "node2", "node3", "node4"],
            lines=["line1", "line2"],
            line_start=Dict("line1" => "node1", "line2" => "node3"),
            line_end=Dict("line1" => "node2", "line2" => "node4"),
            reactance=Dict("line1" => 0.1, "line2" => 0.15),
            resistance=Dict("line1" => 0.01, "line2" => 0.02),
            slack=["node1"]
        )
        
        adjacency, nodes = POMATWO.build_adjacency_list(params, true)
        islands = POMATWO.find_network_islands(adjacency, nodes)
        
        @test length(islands) == 2
        @test (("node1" in islands[1] && "node2" in islands[1]) || 
               ("node1" in islands[2] && "node2" in islands[2]))
        @test (("node3" in islands[1] && "node4" in islands[1]) || 
               ("node3" in islands[2] && "node4" in islands[2]))
    end
    
    @testset "Integration - Validation detects omitted nodes" begin
        params = create_test_params_ptdf(
            nodes=["node1", "node2", "node3", "node4"],
            lines=["line1"],
            dc_lines=["dc1"],
            line_start=Dict("line1" => "node1"),
            line_end=Dict("line1" => "node2"),
            dc_start=Dict("dc1" => "node2"),
            dc_end=Dict("dc1" => "node3"),
            reactance=Dict("line1" => 0.1),
            resistance=Dict("line1" => 0.01),
            slack=["node1"]
        )
        
        report = POMATWO.DataReport()
        POMATWO.validate_network_topology(report, params)
        
        warnings = POMATWO.get_warnings(report)
        errors = POMATWO.get_errors(report)
        
        # Should have warning about DC-only node
        dc_only_warning = any(w -> occursin("DC lines", w.message) && occursin("node3", w.message), warnings)
        @test dc_only_warning
        
        # Should have error about isolated node
        isolated_error = any(e -> occursin("isolated", e.message) && occursin("node4", e.message), errors)
        @test isolated_error
    end
    
    @testset "PTDF calculation excludes omitted nodes" begin
        # Create a simple 4-node network with one DC-only node
        nodes = ["node1", "node2", "node3", "node4"]
        lines = ["line1", "line2"]
        dc_lines = ["dc1"]
        
        params = create_test_params_ptdf(
            nodes=nodes,
            lines=lines,
            dc_lines=dc_lines,
            line_start=Dict("line1" => "node1", "line2" => "node2"),
            line_end=Dict("line1" => "node2", "line2" => "node3"),
            dc_start=Dict("dc1" => "node3"),
            dc_end=Dict("dc1" => "node4"),
            reactance=Dict("line1" => 0.1, "line2" => 0.15),
            resistance=Dict("line1" => 0.01, "line2" => 0.02),
            slack=["node1"]
        )
        
        # Verify node4 is identified as DC-only (should be omitted)
        omit_list = POMATWO.get_nodes_to_omit_for_ptdf(params)
        @test "node4" in omit_list
        
        # Create h and b matrices for PTDF calculation
        n_lines = length(lines)
        n_nodes = length(nodes)
        h = zeros(Float64, n_lines, n_nodes)
        b = zeros(Float64, n_nodes, n_nodes)
        
        # Simple setup: line1 connects node1-node2, line2 connects node2-node3
        h[1, 1] = -1.0  # line1 from node1
        h[1, 2] = 1.0   # line1 to node2
        h[2, 2] = -1.0  # line2 from node2
        h[2, 3] = 1.0   # line2 to node3
        
        # Simple b matrix (should be semi-definite)
        b[1, 1] = 10.0
        b[1, 2] = -10.0
        b[2, 1] = -10.0
        b[2, 2] = 20.0
        b[2, 3] = -10.0
        b[3, 2] = -10.0
        b[3, 3] = 10.0
        # node4 rows/cols remain zero (DC-only node)
        
        # Run PTDF calculation
        POMATWO.calc_PTDF!(h, b, params.slack, nodes, lines, params)
        
        # Check that PTDF values exist
        @test haskey(params.ptdf, ("line1", "node1"))
        @test haskey(params.ptdf, ("line1", "node4"))
        
        # PTDF values for DC-only node4 should be zero (excluded from calculation)
        @test params.ptdf[("line1", "node4")] == 0.0
        @test params.ptdf[("line2", "node4")] == 0.0
    end
end
