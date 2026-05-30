using Test
using JuMP.Containers

# Helper to create minimal params for GSK testing
function create_gsk_test_params(nodes::Vector{String}, zones::Vector{String}, node_zone_map::Dict{String,String};
                                lines::Vector{String}=String[],
                                acline_capacity::Dict{String,Float64}=Dict{String,Float64}())
    sets = POMATWO.Sets(
        N=nodes,
        L=lines,
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

        G = POMATWO.build_gsk(params, POMATWO.FlatGSK())

        @test G isa JuMP.Containers.DenseAxisArray
        @test size(G) == (4, 2)
        @test collect(axes(G, 1)) == nodes   # sorted: ["N1","N2","N3","N4"]
        @test collect(axes(G, 2)) == zones   # sorted: ["Z1","Z2"]
        @test all(abs.(sum(G.data; dims=1) .- 1) .< 1e-12)  # columns sum to 1

        # Equal split: N1,N2 in Z1 → 0.5; N3,N4 in Z2 → 0.5
        @test G["N1", "Z1"] ≈ 0.5
        @test G["N2", "Z1"] ≈ 0.5
        @test G["N3", "Z2"] ≈ 0.5
        @test G["N4", "Z2"] ≈ 0.5

        # Cross-zone entries are zero
        @test G["N1", "Z2"] == 0.0 && G["N2", "Z2"] == 0.0
        @test G["N3", "Z1"] == 0.0 && G["N4", "Z1"] == 0.0
    end

    @testset "GSK Strategy: CustomWeightsGSK (proportional split)" begin
        nodes = ["N1", "N2", "N3", "N4"]
        zones = ["Z1", "Z2"]
        node_zone_map = Dict("N1" => "Z1", "N2" => "Z1", "N3" => "Z2", "N4" => "Z2")
        params = create_gsk_test_params(nodes, zones, node_zone_map)

        # Custom weights: [10, 30, 50, 10]
        # Z1 total = 40 → N1=0.25, N2=0.75; Z2 total = 60 → N3=5/6, N4=1/6
        custom_weights = [10.0, 30.0, 50.0, 10.0]
        G = POMATWO.build_gsk(params, POMATWO.CustomWeightsGSK(custom_weights))

        @test size(G) == (4, 2)
        @test all(abs.(sum(G.data; dims=1) .- 1) .< 1e-12)

        @test G["N1", "Z1"] ≈ 0.25
        @test G["N2", "Z1"] ≈ 0.75
        @test G["N3", "Z2"] ≈ 50/60
        @test G["N4", "Z2"] ≈ 10/60
    end

    @testset "GSK Strategy: GmaxGSK (capacity-weighted)" begin
        nodes = ["N1", "N2", "N3"]
        zones = ["Z1", "Z2"]
        node_zone_map = Dict("N1" => "Z1", "N2" => "Z1", "N3" => "Z2")

        plants = ["P1", "P2", "P3", "P4"]
        sets = POMATWO.Sets(
            N=nodes, L=String[], Z=zones, P=plants, S=String[],
            DC=String[], DISP=String[], NDISP=String[],
            NTC=Tuple{String,String}[], PRS=String[], PRS_STO=String[]
        )
        params = POMATWO.Parameters(
            sets=sets,
            node2zone=node_zone_map,
            plant2node=Dict("P1" => "N1", "P2" => "N2", "P3" => "N2", "P4" => "N3"),
            gmax=Dict("P1" => 100.0, "P2" => 200.0, "P3" => 100.0, "P4" => 400.0)
        )

        # Total capacity: N1=100, N2=300, N3=400
        # Z1 total=400 → N1=0.25, N2=0.75; Z2 total=400 → N3=1.0
        G = POMATWO.build_gsk(params, POMATWO.GmaxGSK())

        @test size(G) == (3, 2)
        @test G["N1", "Z1"] ≈ 100/400
        @test G["N2", "Z1"] ≈ 300/400
        @test G["N3", "Z2"] ≈ 1.0
    end

    @testset "GSK Strategy: DispOnlyGSK (dispatchable-only capacity-weighted)" begin
        nodes = ["N1", "N2"]
        zones = ["Z1"]
        node_zone_map = Dict("N1" => "Z1", "N2" => "Z1")
        plants = ["P1_disp", "P2_ndisp"]
        sets = POMATWO.Sets(
            N=nodes, L=String[], Z=zones, P=plants, S=String[],
            DC=String[], DISP=["P1_disp"], NDISP=["P2_ndisp"],
            NTC=Tuple{String,String}[], PRS=String[], PRS_STO=String[]
        )
        params = POMATWO.Parameters(
            sets=sets,
            node2zone=node_zone_map,
            plant2node=Dict("P1_disp" => "N1", "P2_ndisp" => "N2"),
            gmax=Dict("P1_disp" => 100.0, "P2_ndisp" => 200.0)
        )

        G = POMATWO.build_gsk(params, POMATWO.DispOnlyGSK())

        @test size(G) == (2, 1)
        # Only dispatchable P1_disp at N1 contributes → N1=1.0, N2=0.0
        @test G["N1", "Z1"] ≈ 1.0
        @test G["N2", "Z1"] ≈ 0.0
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
        line_labels = ["L1", "L2", "L3"]
        node_labels = ["N1", "N2", "N3", "N4"]
        l, n, z = 3, 4, 2
        zones = ["Z1", "Z2"]
        node_zone_map = Dict("N1" => "Z1", "N2" => "Z1", "N3" => "Z2", "N4" => "Z2")
        params = create_gsk_test_params(node_labels, zones, node_zone_map)

        # Build PTDF as DenseAxisArray (required by zonal_ptdf)
        PTDF_data = reshape(collect(1.0:(l*n)), l, n) .* 1e-3
        PTDF = JuMP.Containers.DenseAxisArray(PTDF_data, line_labels, node_labels)

        custom_weights = [10.0, 30.0, 50.0, 10.0]
        # Build G without pinning node order — zonal_ptdf must align axes internally
        G = POMATWO.build_gsk(params, POMATWO.CustomWeightsGSK(custom_weights))

        PTDFz = POMATWO.zonal_ptdf(PTDF, G)

        @test PTDFz isa JuMP.Containers.DenseAxisArray
        @test size(PTDFz) == (l, z)
        @test collect(axes(PTDFz, 1)) == line_labels
        @test collect(axes(PTDFz, 2)) == zones
        # Verify correctness via axis-aware dot product (independent of internal storage order)
        for line in line_labels, zone in zones
            expected = sum(PTDF[line, node] * G[node, zone] for node in node_labels)
            @test PTDFz[line, zone] ≈ expected atol=1e-4
        end
    end

    @testset "zone→zone PTDF (export→import) from zonal PTDF" begin
        line_labels = ["L1", "L2", "L3"]
        zone_labels = ["Z1", "Z2"]

        PTDFz_data = [
            0.10  0.40;   # line1
            0.30  0.20;   # line2
            0.05  0.15    # line3
        ]
        # zone_to_zone_ptdf requires a DenseAxisArray input
        PTDFz = JuMP.Containers.DenseAxisArray(PTDFz_data, line_labels, zone_labels)

        PTDFzz = POMATWO.zone_to_zone_ptdf(PTDFz; exclude_self=true)
        pairs = collect(axes(PTDFzz, 2))

        @test PTDFzz isa JuMP.Containers.DenseAxisArray
        @test size(PTDFzz) == (3, 2)
        @test length(pairs) == 2

        # Implementation: for z_import in zones, for z_export in zones (skip self)
        # zi=Z1, zo=Z2 → PTDFz[:,Z1]-PTDFz[:,Z2], pair=("Z2","Z1")
        # zi=Z2, zo=Z1 → PTDFz[:,Z2]-PTDFz[:,Z1], pair=("Z1","Z2")
        @test pairs[1] == ("Z2", "Z1")
        @test pairs[2] == ("Z1", "Z2")

        expected_z2z1 = PTDFz_data[:, 1] .- PTDFz_data[:, 2]
        @test [PTDFzz[l, ("Z2","Z1")] for l in line_labels] ≈ expected_z2z1

        expected_z1z2 = PTDFz_data[:, 2] .- PTDFz_data[:, 1]
        @test [PTDFzz[l, ("Z1","Z2")] for l in line_labels] ≈ expected_z1z2

        # exclude_self=false → z*z = 4 pairs
        PTDFzz_all = POMATWO.zone_to_zone_ptdf(PTDFz; exclude_self=false)
        @test size(PTDFzz_all, 2) == 4
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

        # Z2 has zero weights → empty zone → should get flat distribution
        zero_weights = [5.0, 0.0, 0.0, 20.0, 20.0]
        G = POMATWO.build_gsk(
            params,
            POMATWO.CustomWeightsGSK(zero_weights);
            normalize_empty=:flat
        )

        @test size(G) == (5, 3)
        @test G["N2", "Z2"] ≈ 0.5  # uniform split within empty zone
        @test G["N3", "Z2"] ≈ 0.5
        @test G["N1", "Z1"] ≈ 1.0  # Z1 has only one node
        @test G["N4", "Z3"] ≈ 0.5
        @test G["N5", "Z3"] ≈ 0.5
    end

    @testset "Node and zone ordering" begin
        nodes = ["N3", "N1", "N2"]  # Unsorted input
        zones = ["ZB", "ZA"]        # Unsorted input
        node_zone_map = Dict("N1" => "ZA", "N2" => "ZA", "N3" => "ZB")
        params = create_gsk_test_params(nodes, zones, node_zone_map)

        # Default: sorted internally
        G1 = POMATWO.build_gsk(params, POMATWO.FlatGSK())
        @test collect(axes(G1, 1)) == ["N1", "N2", "N3"]  # sorted
        @test collect(axes(G1, 2)) == ["ZA", "ZB"]        # sorted

        # Explicit order preserved
        G2 = POMATWO.build_gsk(params, POMATWO.FlatGSK(); node_order=nodes, zone_order=zones)
        @test collect(axes(G2, 1)) == nodes   # ["N3","N1","N2"]
        @test collect(axes(G2, 2)) == zones   # ["ZB","ZA"]
        @test size(G2) == (3, 2)
    end

    @testset "define_cne!: filter Critical Network Elements in-place" begin
        lines = ["L1", "L2", "L3", "L4"]
        zone_pairs = [("Z1", "Z2"), ("Z2", "Z1")]

        PTDFzz_data = [
            0.08  -0.08;   # L1: max_abs=0.08 < 0.10 → removed
            0.15   0.02;   # L2: max_abs=0.15 > 0.10 → kept
            0.01  -0.12;   # L3: max_abs=0.12 > 0.10 → kept
            0.20  -0.18    # L4: max_abs=0.20 > 0.10 → kept
        ]
        PTDFzz = JuMP.Containers.DenseAxisArray(PTDFzz_data, lines, zone_pairs)

        nodes = ["N1", "N2"]
        zones = ["Z1", "Z2"]
        node_zone_map = Dict("N1" => "Z1", "N2" => "Z2")
        # lines kwarg populates params.sets.L so define_cne! can initialize params.cne
        params = create_gsk_test_params(nodes, zones, node_zone_map; lines=lines)

        @test isempty(params.cne)  # starts empty
        POMATWO.define_cne!(params, PTDFzz; threshold=0.10)

        @test "L1" ∉ params.cne       # max_abs=0.08 < 0.10
        @test "L2" in params.cne      # max_abs=0.15 > 0.10
        @test "L3" in params.cne      # max_abs=0.12 > 0.10
        @test "L4" in params.cne      # max_abs=0.20 > 0.10
        @test length(params.cne) == 3

        # Second call: cne already populated (L2,L3,L4); apply stricter threshold
        POMATWO.define_cne!(params, PTDFzz; threshold=0.14)
        @test "L2" in params.cne      # 0.15 > 0.14 → kept
        @test "L3" ∉ params.cne       # 0.12 < 0.14 → removed
        @test "L4" in params.cne      # 0.20 > 0.14 → kept
        @test length(params.cne) == 2
    end

    @testset "calc_ram: remaining available margin (70%-rule)" begin
        lines = ["L1", "L2"]
        zones = ["Z1", "Z2"]
        nodes = ["N1", "N2"]
        T = 1:2

        node_zone_map = Dict("N1" => "Z1", "N2" => "Z2")
        sets = POMATWO.Sets(
            N=nodes, L=lines, Z=zones, P=String[], S=String[],
            DC=String[], DISP=String[], NDISP=String[],
            NTC=Tuple{String,String}[], PRS=String[], PRS_STO=String[]
        )
        params = POMATWO.Parameters(
            sets=sets,
            node2zone=node_zone_map,
            nodes_in_zone=Dict("Z1" => ["N1"], "Z2" => ["N2"]),
            acline_capacity=Dict("L1" => 100.0, "L2" => 200.0),
            cne=copy(lines)
        )

        # Build PTDFz (l×z) and PTDFzz (l×zone_pairs)
        PTDFz_data = [0.3 0.1; 0.2 0.4]
        PTDFz = JuMP.Containers.DenseAxisArray(PTDFz_data, lines, zones)
        PTDFzz = POMATWO.zone_to_zone_ptdf(PTDFz; exclude_self=true)

        PTDFn_data = [0.3 0.1; 0.2 0.4]
        PTDFn = JuMP.Containers.DenseAxisArray(PTDFn_data, lines, nodes)

        # Mock TwoDayAhead results
        lineflow_data = [50.0 -30.0; 80.0 60.0]   # lines × T
        netinput_data = [10.0 -20.0; -10.0 20.0]  # nodes × T
        lineflows   = JuMP.Containers.DenseAxisArray(lineflow_data, lines, collect(T))
        netinput_ac = JuMP.Containers.DenseAxisArray(netinput_data, nodes, collect(T))
        TwoDayAhead_results = Dict(:lineflows => lineflows, :netinput_ac => netinput_ac)

        ram = POMATWO.calc_ram(params, TwoDayAhead_results, PTDFz, PTDFzz, PTDFn, T;
                               minRAM=0.7, FRM=0.1)

        @test ram isa JuMP.Containers.DenseAxisArray
        @test size(ram) == (2, 2, 2)   # lines × T × directions
        @test collect(axes(ram, 1)) == lines
        @test collect(axes(ram, 3)) == ["pos", "neg"]
        @test all(isfinite.(ram.data))

        # 70%-rule: RAM_pos = max(init_pos, minRAM*Fmax) ≥ minRAM*Fmax
        #           RAM_neg = min(init_neg, minRAM*(-Fmax)) ≤ -minRAM*Fmax
        for l in lines, t in T
            fmax = params.acline_capacity[l]
            @test ram[l, t, "pos"] ≥ 0.7 * fmax - 1e-8
            @test ram[l, t, "neg"] ≤ -0.7 * fmax + 1e-8
        end
    end
end
