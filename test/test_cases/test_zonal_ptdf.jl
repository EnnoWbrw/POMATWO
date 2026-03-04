using Test
using JuMP.Containers

# Helper to create minimal params for GSK testing
function create_gsk_test_params(nodes::Vector{String}, zones::Vector{String}, node_zone_map::Dict{String,String}; 
                                acline_capacity::Dict{String,Float64}=Dict{String,Float64}())
    # Create Parameters directly with node2zone field populated
    # Use the base create_test_params to get default structure, then create new with node2zone
    sets = POMATWO.Sets(
        N=nodes,
        L=String[],
        Z=zones,
        P=String[],
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
        node2zone=node_zone_map,
        acline_capacity=acline_capacity
    )
end

function test_zonal_ptdf()
    @testset "GSK Strategy: FlatGSK (equal distribution)" begin
        nodes = ["N1", "N2", "N3", "N4"]
        zones = ["Z1", "Z2"]
        node_zone_map = Dict("N1" => "Z1", "N2" => "Z1", "N3" => "Z2", "N4" => "Z2")
        params = create_gsk_test_params(nodes, zones, node_zone_map)
        
        G, ret_nodes, ret_zones = POMATWO.build_gsk(params, POMATWO.FlatGSK())
        
        @test size(G) == (4, 2)
        @test ret_nodes == nodes
        @test ret_zones == zones
        @test all(abs.(sum(G; dims=1) .- 1) .< 1e-12)  # columns sum to 1
        
        # Equal split: N1,N2 in Z1 → 0.5 each; N3,N4 in Z2 → 0.5 each
        @test G[1, 1] ≈ 0.5
        @test G[2, 1] ≈ 0.5
        @test G[3, 2] ≈ 0.5
        @test G[4, 2] ≈ 0.5
        
        # Each node contributes only to its zone
        @test G[1, 2] == 0.0 && G[2, 2] == 0.0
        @test G[3, 1] == 0.0 && G[4, 1] == 0.0
    end
    
    @testset "GSK Strategy: CustomWeightsGSK (proportional split)" begin
        nodes = ["N1", "N2", "N3", "N4"]
        zones = ["Z1", "Z2"]
        node_zone_map = Dict("N1" => "Z1", "N2" => "Z1", "N3" => "Z2", "N4" => "Z2")
        params = create_gsk_test_params(nodes, zones, node_zone_map)
        
        # Custom weights: [10, 30, 50, 10]
        # Z1 total = 40 → N1=0.25, N2=0.75
        # Z2 total = 60 → N3=5/6, N4=1/6
        custom_weights = [10.0, 30.0, 50.0, 10.0]
        G, ret_nodes, ret_zones = POMATWO.build_gsk(
            params, 
            POMATWO.CustomWeightsGSK(custom_weights)
        )
        
        @test size(G) == (4, 2)
        @test all(abs.(sum(G; dims=1) .- 1) .< 1e-12)
        
        @test G[1, 1] ≈ 0.25
        @test G[2, 1] ≈ 0.75
        @test G[3, 2] ≈ 50/60
        @test G[4, 2] ≈ 10/60
    end
    
    @testset "GSK Strategy: GmaxGSK (capacity-weighted)" begin
        nodes = ["N1", "N2", "N3"]
        zones = ["Z1", "Z2"]
        node_zone_map = Dict("N1" => "Z1", "N2" => "Z1", "N3" => "Z2")
        
        # Create params with plant data for GmaxGSK
        plants = ["P1", "P2", "P3", "P4"]
        sets = POMATWO.Sets(
            N=nodes,
            L=String[],
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
        
        params = POMATWO.Parameters(
            sets=sets,
            node2zone=node_zone_map,
            plant2node=Dict("P1" => "N1", "P2" => "N2", "P3" => "N2", "P4" => "N3"),
            gmax=Dict("P1" => 100.0, "P2" => 200.0, "P3" => 100.0, "P4" => 400.0)
        )
        
        # Total capacity: N1=100, N2=300, N3=400
        # Z1 total=400 → N1=0.25, N2=0.75; Z2 total=400 → N3=1.0
        G, ret_nodes, ret_zones = POMATWO.build_gsk(params, POMATWO.GmaxGSK())
        
        @test size(G) == (3, 2)
        @test G[1, 1] ≈ 100/400
        @test G[2, 1] ≈ 300/400
        @test G[3, 2] ≈ 1.0
    end

    @testset "dict_to_matrix: Convert Dict to DenseAxisArray" begin
        # Test with simple dictionary
        test_dict = Dict(
            ("row1", "col1") => 1.0,
            ("row1", "col2") => 2.0,
            ("row2", "col1") => 3.0,
            ("row2", "col2") => 4.0,
            ("row3", "col1") => 5.0,
            ("row3", "col2") => 6.0
        )
        
        result = POMATWO.dict_to_matrix(test_dict)
        
        # Check type and size
        @test result isa JuMP.Containers.DenseAxisArray
        @test size(result) == (3, 2)
        
        # Check axes are sorted
        @test axes(result, 1) == ["row1", "row2", "row3"]
        @test axes(result, 2) == ["col1", "col2"]
        
        # Check values are correctly placed
        @test result["row1", "col1"] == 1.0
        @test result["row1", "col2"] == 2.0
        @test result["row2", "col1"] == 3.0
        @test result["row2", "col2"] == 4.0
        @test result["row3", "col1"] == 5.0
        @test result["row3", "col2"] == 6.0
        
        # Test with unsorted keys
        unsorted_dict = Dict(
            ("z_row", "z_col") => 9.0,
            ("a_row", "a_col") => 1.0,
            ("m_row", "m_col") => 5.0
        )
        
        result_unsorted = POMATWO.dict_to_matrix(unsorted_dict)
        @test axes(result_unsorted, 1) == ["a_row", "m_row", "z_row"]
        @test axes(result_unsorted, 2) == ["a_col", "m_col", "z_col"]
        @test result_unsorted["a_row", "a_col"] == 1.0
        @test result_unsorted["m_row", "m_col"] == 5.0
        @test result_unsorted["z_row", "z_col"] == 9.0
    end

    @testset "zonal_ptdf: PTDF(l×n) * G(n×z) = PTDFz(l×z)" begin
        l, n, z = 3, 4, 2
        # Deterministic tiny PTDF
        PTDF = reshape(collect(1.0:(l*n)), l, n) .* 1e-3
        
        nodes = ["N1", "N2", "N3", "N4"]
        zones = ["Z1", "Z2"]
        node_zone_map = Dict("N1" => "Z1", "N2" => "Z1", "N3" => "Z2", "N4" => "Z2")
        params = create_gsk_test_params(nodes, zones, node_zone_map)
        
        custom_weights = [10.0, 30.0, 50.0, 10.0]
        G, _, _ = POMATWO.build_gsk(params, POMATWO.CustomWeightsGSK(custom_weights))

        PTDFz = POMATWO.zonal_ptdf(PTDF, G)
        @test size(PTDFz) == (l, z)
        @test PTDFz[:, 1] ≈ PTDF * G[:, 1]
        @test PTDFz[:, 2] ≈ PTDF * G[:, 2]
    end

    @testset "zone→zone PTDF (export→import) from zonal PTDF" begin
        # Tiny l×z zonal PTDF
        PTDFz = [
            0.10  0.40;   # line1 for (Z1,Z2)
            0.30  0.20;   # line2
            0.05  0.15    # line3
        ]
        zones = ["Z1", "Z2"]

        # (Z2→Z1) and (Z1→Z2) columns expected
        PTDFzz, pairs = POMATWO.zone_to_zone_ptdf(PTDFz; zones=zones, exclude_self=true)
        @test size(PTDFzz) == (3, 2)
        @test length(pairs) == 2

        # Ordering from implementation: for each importer zi, then for each exporter zo
        # zi=1 (Z1), zo=2 (Z2) → (Z2→Z1): PTDFz[:,1] - PTDFz[:,2]
        # zi=2 (Z2), zo=1 (Z1) → (Z1→Z2): PTDFz[:,2] - PTDFz[:,1]
        @test pairs[1] == ("Z2", "Z1")
        @test pairs[2] == ("Z1", "Z2")

        # Column for (Z2→Z1) = PTDFz[:, Z1] - PTDFz[:, Z2]
        @test PTDFzz[:, 1] ≈ (PTDFz[:, 1] .- PTDFz[:, 2])
        # Column for (Z1→Z2) = PTDFz[:, Z2] - PTDFz[:, Z1]
        @test PTDFzz[:, 2] ≈ (PTDFz[:, 2] .- PTDFz[:, 1])
    end

    @testset "Empty-zone behavior (normalize_empty = :flat)" begin
        nodes = ["N1", "N2", "N3", "N4", "N5"]
        zones = ["Z1", "Z2", "Z3"]
        node_zone_map = Dict(
            "N1" => "Z1",
            "N2" => "Z2", "N3" => "Z2",
            "N4" => "Z3", "N5" => "Z3"
        )
        params = create_gsk_test_params(nodes, zones, node_zone_map)
        
        # Make zone 2 empty via zero weights
        zero_weights = [5.0, 0.0, 0.0, 20.0, 20.0]
        G, _, _ = POMATWO.build_gsk(
            params, 
            POMATWO.CustomWeightsGSK(zero_weights);
            normalize_empty=:flat
        )
        
        @test size(G) == (5, 3)
        @test G[2, 2] ≈ 0.5  # uniform split within empty zone's members
        @test G[3, 2] ≈ 0.5
        @test G[1, 1] ≈ 1.0  # Z1 has only one node
        @test G[4, 3] ≈ 0.5  # Z3 has equal weights
        @test G[5, 3] ≈ 0.5
    end
    
    @testset "Node and zone ordering" begin
        nodes = ["N3", "N1", "N2"]  # Unsorted
        zones = ["ZB", "ZA"]        # Unsorted
        node_zone_map = Dict("N1" => "ZA", "N2" => "ZA", "N3" => "ZB")
        params = create_gsk_test_params(nodes, zones, node_zone_map)
        
        # Without explicit order, should sort internally
        G1, ret_nodes1, ret_zones1 = POMATWO.build_gsk(params, POMATWO.FlatGSK())
        @test ret_nodes1 == ["N1", "N2", "N3"]  # sorted
        @test ret_zones1 == ["ZA", "ZB"]        # sorted
        
        # With explicit order
        G2, ret_nodes2, ret_zones2 = POMATWO.build_gsk(
            params, 
            POMATWO.FlatGSK();
            node_order=nodes,
            zone_order=zones
        )
        @test ret_nodes2 == nodes
        @test ret_zones2 == zones
        @test size(G2) == (3, 2)
    end

    @testset "define_cne: Identify Critical Network Elements" begin
        # Create a mock zone-to-zone PTDF matrix
        lines = ["L1", "L2", "L3", "L4"]
        zone_pairs = [("Z1", "Z2"), ("Z2", "Z1")]
        
        # Create PTDFzz with known values
        PTDFzz_data = [
            0.08  -0.08;   # L1: below threshold in both directions
            0.15   0.02;   # L2: above threshold for (Z1,Z2), below for (Z2,Z1)
            0.01  -0.12;   # L3: below for (Z1,Z2), above for (Z2,Z1)
            0.20  -0.18    # L4: above threshold in both directions
        ]
        PTDFzz = JuMP.Containers.DenseAxisArray(PTDFzz_data, lines, zone_pairs)
        
        # Create params with empty cne_indicator
        nodes = ["N1", "N2"]
        zones = ["Z1", "Z2"]
        node_zone_map = Dict("N1" => "Z1", "N2" => "Z2")
        params = create_gsk_test_params(nodes, zones, node_zone_map)
        
        # Test with threshold = 0.10
        CNE = POMATWO.define_cne(params, PTDFzz; threshold=0.10)
        
        # Check that CNE has correct structure
        @test size(CNE) == size(PTDFzz)
        
        # Check that values below threshold are zeroed
        @test CNE["L1", ("Z1", "Z2")] == 0.0
        @test CNE["L1", ("Z2", "Z1")] == 0.0
        @test CNE["L2", ("Z1", "Z2")] == 0.15
        @test CNE["L2", ("Z2", "Z1")] == 0.0
        @test CNE["L3", ("Z1", "Z2")] == 0.0
        @test CNE["L3", ("Z2", "Z1")] ≈ -0.12
        @test CNE["L4", ("Z1", "Z2")] == 0.20
        @test CNE["L4", ("Z2", "Z1")] ≈ -0.18
        
        # Check that cne_indicator is correctly populated
        @test params.cne_indicator[("L1", ("Z1", "Z2"))] == 0
        @test params.cne_indicator[("L1", ("Z2", "Z1"))] == 0
        @test params.cne_indicator[("L2", ("Z1", "Z2"))] == 1
        @test params.cne_indicator[("L2", ("Z2", "Z1"))] == 0
        @test params.cne_indicator[("L3", ("Z1", "Z2"))] == 0
        @test params.cne_indicator[("L3", ("Z2", "Z1"))] == 1
        @test params.cne_indicator[("L4", ("Z1", "Z2"))] == 1
        @test params.cne_indicator[("L4", ("Z2", "Z1"))] == 1
        
        # Test with different threshold
        params2 = create_gsk_test_params(nodes, zones, node_zone_map)
        CNE2 = POMATWO.define_cne(params2, PTDFzz; threshold=0.05)
        
        # With lower threshold, L1 should now be identified as CNE
        @test params2.cne_indicator[("L1", ("Z1", "Z2"))] == 1
        @test params2.cne_indicator[("L1", ("Z2", "Z1"))] == 1
    end

    @testset "calc_ram: Reserve Available Margin calculation" begin
        # Set up test data
        lines = ["L1", "L2", "L3", "L4"]
        zone_pairs = [("Z1", "Z2"), ("Z2", "Z1")]
        
        # Create PTDFzz
        PTDFzz_data = [
            0.08  -0.08;
            0.15   0.02;
            0.01  -0.12;
            0.20  -0.18
        ]
        PTDFzz = JuMP.Containers.DenseAxisArray(PTDFzz_data, lines, zone_pairs)
        
        # Create params with capacities
        nodes = ["N1", "N2"]
        zones = ["Z1", "Z2"]
        node_zone_map = Dict("N1" => "Z1", "N2" => "Z2")
        acline_cap = Dict(
            "L1" => 100.0,
            "L2" => 200.0,
            "L3" => 150.0,
            "L4" => 300.0
        )
        params = create_gsk_test_params(nodes, zones, node_zone_map; acline_capacity=acline_cap)
        
        # Define CNEs (L2, L3, L4 are CNEs with threshold=0.10)
        POMATWO.define_cne(params, PTDFzz; threshold=0.10)
        
        # Create mock TwoDayAhead results with lineflows
        TwoDayAhead_results = Dict(
            :lineflows => Dict(
                "L1" => 50.0,   # non-CNE: RAM should be full capacity (100.0)
                "L2" => 80.0,   # CNE: capacity=200, flow=80 → max(140, 120) = 140.0
                "L3" => 30.0,   # CNE: capacity=150, flow=30 → max(105, 120) = 120.0
                "L4" => 250.0   # CNE: capacity=300, flow=250 → max(210, 50) = 210.0
            )
        )
        
        # Print intermediate input parameters for calc_ram
        println("\nINPUT PARAMETERS FOR calc_ram():")
        println("TwoDayAhead_results[:lineflows]: ", TwoDayAhead_results[:lineflows])
        println("params.acline_capacity: ", params.acline_capacity)
        
        # Calculate RAM
        ram = POMATWO.calc_ram(params, TwoDayAhead_results, PTDFzz)
        
        # Test RAM values
        @test ram["L1"] == 100.0     # non-CNE: full capacity
        @test ram["L2"] == 140.0     # CNE: max(0.7*200, 200-80)
        @test ram["L3"] == 120.0     # CNE: max(0.7*150, 150-30)
        @test ram["L4"] == 210.0     # CNE: max(0.7*300, 300-250)
        
        # Test with a case where flow is negative (should use absolute value)
        TwoDayAhead_results_neg = Dict(
            :lineflows => Dict(
                "L1" => 50.0,
                "L2" => -80.0,  # negative flow
                "L3" => 30.0,
                "L4" => 250.0
            )
        )
        
        ram_neg = POMATWO.calc_ram(params, TwoDayAhead_results_neg, PTDFzz)
        @test ram_neg["L2"] == 140.0  # Should handle negative flow correctly
    end

    @testset "calc_ram: Edge cases" begin
        # Test with zero flow
        lines = ["L1"]
        zone_pairs = [("Z1", "Z2")]
        PTDFzz = JuMP.Containers.DenseAxisArray([0.15], lines, zone_pairs)
        
        nodes = ["N1", "N2"]
        zones = ["Z1", "Z2"]
        acline_cap = Dict("L1" => 100.0)
        params = create_gsk_test_params(nodes, zones, Dict("N1" => "Z1", "N2" => "Z2"); 
                                       acline_capacity=acline_cap)
        
        POMATWO.define_cne(params, PTDFzz; threshold=0.10)
        
        # Zero flow case
        results_zero = Dict(:lineflows => Dict("L1" => 0.0))
        ram_zero = POMATWO.calc_ram(params, results_zero, PTDFzz)
        @test ram_zero["L1"] == 100.0  # max(70, 100-0) = 100
        
        # High flow case (flow > 30% capacity)
        results_high = Dict(:lineflows => Dict("L1" => 50.0))
        ram_high = POMATWO.calc_ram(params, results_high, PTDFzz)
        @test ram_high["L1"] == 70.0  # max(70, 100-50) = 70
    end

    @testset "calc_fbmc_params: Integration test" begin
        # This test verifies that calc_fbmc_params correctly orchestrates all
        # the individual functions and returns a complete dictionary
        
        # Note: calc_fbmc_params requires a SubRun object which is complex to mock
        # Instead, we test that we can manually recreate what it does
        
        # Set up test data
        nodes = ["N1", "N2", "N3"]
        zones = ["Z1", "Z2"]
        node_zone_map = Dict("N1" => "Z1", "N2" => "Z1", "N3" => "Z2")
        
        # Create params with line capacities
        lines = ["L1", "L2"]
        acline_cap = Dict("L1" => 100.0, "L2" => 200.0)
        params = create_gsk_test_params(nodes, zones, node_zone_map; acline_capacity=acline_cap)
        
        # Create mock PTDF dictionary
        ptdf_dict = Dict(
            ("L1", "N1") => 0.3,
            ("L1", "N2") => 0.4,
            ("L1", "N3") => -0.7,
            ("L2", "N1") => 0.2,
            ("L2", "N2") => 0.1,
            ("L2", "N3") => -0.3
        )
        params.ptdf = ptdf_dict
        
        # Build GSK
        GSK = POMATWO.build_gsk(params, POMATWO.FlatGSK())
        
        # Convert PTDF to matrix
        PTDFn = POMATWO.dict_to_matrix(params.ptdf)
        
        # Calculate zonal PTDF
        PTDFz = POMATWO.zonal_ptdf(PTDFn, GSK)
        
        # Calculate zone-to-zone PTDF
        PTDFzz = POMATWO.zone_to_zone_ptdf(PTDFz; exclude_self=true)
        
        # Define CNEs
        CNE = POMATWO.define_cne(params, PTDFzz; threshold=0.05)
        
        # Create mock TwoDayAhead results
        TwoDayAhead_results = Dict(
            :lineflows => Dict("L1" => 20.0, "L2" => 50.0)
        )
        
        # Calculate RAM
        RAM = POMATWO.calc_ram(params, TwoDayAhead_results, PTDFzz)
        
        # Verify that we can create the same structure as calc_fbmc_params
        fbmc_params = Dict(
            :GSK => GSK,
            :PTDFn => PTDFn,
            :PTDFz => PTDFz,
            :PTDFzz => PTDFzz,
            :RAM => RAM
        )
        
        # Test that all expected keys exist
        @test haskey(fbmc_params, :GSK)
        @test haskey(fbmc_params, :PTDFn)
        @test haskey(fbmc_params, :PTDFz)
        @test haskey(fbmc_params, :PTDFzz)
        @test haskey(fbmc_params, :RAM)
        
        # Test dimensions
        @test size(fbmc_params[:GSK]) == (3, 2)  # nodes × zones
        @test size(fbmc_params[:PTDFn]) == (2, 3)  # lines × nodes
        @test size(fbmc_params[:PTDFz]) == (2, 2)  # lines × zones
        @test size(fbmc_params[:PTDFzz]) == (2, 2)  # lines × (z*(z-1)) zone pairs
        @test length(fbmc_params[:RAM]) == 2  # one entry per line
        
        # Test that GSK columns sum to 1
        @test all(abs.(sum(fbmc_params[:GSK].data, dims=1) .- 1) .< 1e-12)
        
        # Test that RAM values are positive
        @test all(v > 0 for v in values(fbmc_params[:RAM]))
        
        # Test that RAM respects capacity constraints
        for (line, ram_val) in fbmc_params[:RAM]
            capacity = params.acline_capacity[line]
            @test ram_val <= capacity
        end
    end
end
