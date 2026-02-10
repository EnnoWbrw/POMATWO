# Helper to create minimal params for GSK testing
function create_gsk_test_params(nodes::Vector{String}, zones::Vector{String}, node_zone_map::Dict{String,String})
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
        node2zone=node_zone_map
    )
end

function test_zonal_ptdf()
    @testset "GSK Strategy: FlatGSK (equal distribution)" begin
        nodes = ["N1", "N2", "N3", "N4"]
        zones = ["Z1", "Z2"]
        node_zone_map = Dict("N1" => "Z1", "N2" => "Z1", "N3" => "Z2", "N4" => "Z2")
        params = create_gsk_test_params(nodes, zones, node_zone_map)
        
        G = POMATWO.build_gsk(params, POMATWO.FlatGSK())
        
        @test size(G) == (4, 2)
        @test collect(axes(G, 1)) == nodes
        @test collect(axes(G, 2)) == zones
        @test all(abs.(sum(G.data; dims=1) .- 1) .< 1e-12)  # columns sum to 1
        
        # Equal split: N1,N2 in Z1 → 0.5 each; N3,N4 in Z2 → 0.5 each
        @test G["N1", "Z1"] ≈ 0.5
        @test G["N2", "Z1"] ≈ 0.5
        @test G["N3", "Z2"] ≈ 0.5
        @test G["N4", "Z2"] ≈ 0.5
        
        # Each node contributes only to its zone
        @test G["N1", "Z2"] == 0.0 && G["N2", "Z2"] == 0.0
        @test G["N3", "Z1"] == 0.0 && G["N4", "Z1"] == 0.0
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
        G = POMATWO.build_gsk(
            params, 
            POMATWO.CustomWeightsGSK(custom_weights)
        )
        
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
        G = POMATWO.build_gsk(params, POMATWO.GmaxGSK())
        
        @test size(G) == (3, 2)
        @test G["N1", "Z1"] ≈ 100/400
        @test G["N2", "Z1"] ≈ 300/400
        @test G["N3", "Z2"] ≈ 1.0
    end

    @testset "zonal_ptdf: PTDF(l×n) * G(n×z) = PTDFz(l×z)" begin
        l, n, z = 3, 4, 2
        # Deterministic tiny PTDF - use string labels matching nodes
        nodes = ["N1", "N2", "N3", "N4"]
        lines = ["L1", "L2", "L3"]
        PTDF = DenseAxisArray(reshape(collect(1.0:(l*n)), l, n) .* 1e-3, lines, nodes)
        
        zones = ["Z1", "Z2"]
        node_zone_map = Dict("N1" => "Z1", "N2" => "Z1", "N3" => "Z2", "N4" => "Z2")
        params = create_gsk_test_params(nodes, zones, node_zone_map)
        
        custom_weights = [10.0, 30.0, 50.0, 10.0]
        G = POMATWO.build_gsk(params, POMATWO.CustomWeightsGSK(custom_weights))

        PTDFz = POMATWO.zonal_ptdf(PTDF, G)
        @test size(PTDFz) == (l, z)
        @test isapprox(PTDFz[:, "Z1"].data, PTDF.data * G[:, "Z1"].data, atol=1e-4)
        @test isapprox(PTDFz[:, "Z2"].data, PTDF.data * G[:, "Z2"].data, atol=1e-4)
    end

    @testset "zone→zone PTDF (export→import) from zonal PTDF" begin
        # Tiny l×z zonal PTDF as DenseAxisArray
        lines = ["L1", "L2", "L3"]
        zones = ["Z1", "Z2"]
        PTDFz_data = [
            0.10  0.40;   # line1 for (Z1,Z2)
            0.30  0.20;   # line2
            0.05  0.15    # line3
        ]
        PTDFz = DenseAxisArray(PTDFz_data, lines, zones)

        # (Z2→Z1) and (Z1→Z2) columns expected
        PTDFzz = POMATWO.zone_to_zone_ptdf(PTDFz; exclude_self=true)
        @test size(PTDFzz.data) == (3, 2)

        # Ordering from implementation: for each importer zi, then for each exporter zo
        # zi=1 (Z1), zo=2 (Z2) → (Z2→Z1): PTDFz[:,1] - PTDFz[:,2]
        # zi=2 (Z2), zo=1 (Z1) → (Z1→Z2): PTDFz[:,2] - PTDFz[:,1]
        @test collect(axes(PTDFzz, 2))[1] == ("Z2", "Z1")
        @test collect(axes(PTDFzz, 2))[2] == ("Z1", "Z2")

        # Column for (Z2→Z1) = PTDFz[:, Z1] - PTDFz[:, Z2]
        @test isapprox(PTDFzz[:, ("Z2", "Z1")].data, PTDFz[:, "Z1"].data .- PTDFz[:, "Z2"].data, atol=1e-4)
        # Column for (Z1→Z2) = PTDFz[:, Z2] - PTDFz[:, Z1]
        @test isapprox(PTDFzz[:, ("Z1", "Z2")].data, PTDFz[:, "Z2"].data .- PTDFz[:, "Z1"].data, atol=1e-4)
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
        G = POMATWO.build_gsk(
            params, 
            POMATWO.CustomWeightsGSK(zero_weights);
            normalize_empty=:flat
        )
        
        @test size(G) == (5, 3)
        @test G["N2", "Z2"] ≈ 0.5  # uniform split within empty zone's members
        @test G["N3", "Z2"] ≈ 0.5
        @test G["N1", "Z1"] ≈ 1.0  # Z1 has only one node
        @test G["N4", "Z3"] ≈ 0.5  # Z3 has equal weights
        @test G["N5", "Z3"] ≈ 0.5
    end
    
    @testset "Node and zone ordering" begin
        nodes = ["N3", "N1", "N2"]  # Unsorted
        zones = ["ZB", "ZA"]        # Unsorted
        node_zone_map = Dict("N1" => "ZA", "N2" => "ZA", "N3" => "ZB")
        params = create_gsk_test_params(nodes, zones, node_zone_map)
        
        # Without explicit order, should sort internally
        G1 = POMATWO.build_gsk(params, POMATWO.FlatGSK())
        @test collect(axes(G1, 1)) == ["N1", "N2", "N3"]  # sorted
        @test collect(axes(G1, 2)) == ["ZA", "ZB"]        # sorted
        
        # With explicit order
        G2 = POMATWO.build_gsk(
            params, 
            POMATWO.FlatGSK();
            node_order=nodes,
            zone_order=zones
        )
        @test collect(axes(G2, 1)) == nodes
        @test collect(axes(G2, 2)) == zones
        @test size(G2) == (3, 2)
    end
end
