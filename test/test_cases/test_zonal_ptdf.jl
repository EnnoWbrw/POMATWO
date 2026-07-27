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
        # All lines connect N1↔N2; both zones are FBCCR so all lines are eligible
        sets = POMATWO.Sets(
            N=nodes, L=lines, Z=zones, P=String[], S=String[],
            DC=String[], DISP=String[], NDISP=String[],
            NTC=Tuple{String,String}[], PRS=String[], PRS_STO=String[],
            FBCCR=zones
        )
        params = POMATWO.Parameters(
            sets=sets,
            node2zone=node_zone_map,
            line_start=Dict("L1"=>"N1","L2"=>"N1","L3"=>"N2","L4"=>"N1"),
            line_end  =Dict("L1"=>"N2","L2"=>"N2","L3"=>"N1","L4"=>"N2")
        )

        @test isempty(params.cne)  # starts empty
        POMATWO.define_cne!(params, PTDFzz; threshold=0.10)

        @test "L1" ∉ params.cne       # max_abs=0.08 < 0.10 (threshold filter)
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

    @testset "define_cne!: FBCCR zone filter — only lines touching an FBCCR zone qualify" begin
        # N1→Z_fb1 (FBCCR), N2→Z_fb2 (FBCCR), N3→Z_ntc (NTC), N4→Z_ntc2 (NTC)
        # L_fb_fb:  N1↔N2 — both endpoints in FBCCR → eligible CNE
        # L_fb_ntc: N1↔N3 — one endpoint in FBCCR   → eligible CNE
        # L_ntc_ntc: N3↔N4 — no FBCCR endpoint      → excluded regardless of PTDF
        nodes = ["N1","N2","N3","N4"]
        zones = ["Z_fb1","Z_fb2","Z_ntc","Z_ntc2"]
        lines_fbccr = ["L_fb_fb","L_fb_ntc","L_ntc_ntc"]
        zone_pairs_fbccr = [("Z_fb1","Z_fb2"),("Z_fb2","Z_fb1")]

        # All lines have PTDF well above any reasonable threshold
        PTDFzz_fbccr_data = [0.30 -0.30; 0.25 -0.25; 0.40 -0.40]
        PTDFzz_fbccr = JuMP.Containers.DenseAxisArray(PTDFzz_fbccr_data, lines_fbccr, zone_pairs_fbccr)

        sets_fbccr = POMATWO.Sets(
            N=nodes, L=lines_fbccr, Z=zones, P=String[], S=String[],
            DC=String[], DISP=String[], NDISP=String[],
            NTC=Tuple{String,String}[], PRS=String[], PRS_STO=String[],
            FBCCR  = ["Z_fb1","Z_fb2"],
            NTCCCR = ["Z_ntc","Z_ntc2"]
        )
        params_fbccr = POMATWO.Parameters(
            sets=sets_fbccr,
            node2zone=Dict("N1"=>"Z_fb1","N2"=>"Z_fb2","N3"=>"Z_ntc","N4"=>"Z_ntc2"),
            line_start=Dict("L_fb_fb"=>"N1","L_fb_ntc"=>"N1","L_ntc_ntc"=>"N3"),
            line_end  =Dict("L_fb_fb"=>"N2","L_fb_ntc"=>"N3","L_ntc_ntc"=>"N4")
        )

        POMATWO.define_cne!(params_fbccr, PTDFzz_fbccr; threshold=0.05)

        @test "L_fb_fb"   in params_fbccr.cne   # both endpoints in FBCCR → included
        @test "L_fb_ntc"  in params_fbccr.cne   # one endpoint in FBCCR   → included
        @test "L_ntc_ntc" ∉ params_fbccr.cne    # no endpoint in FBCCR    → excluded
        @test length(params_fbccr.cne) == 2
    end

    @testset "define_cne!: empty FBCCR set → no lines become CNEs" begin
        lines_empty = ["L1","L2"]
        zone_pairs_empty = [("Z1","Z2"),("Z2","Z1")]
        PTDFzz_empty = JuMP.Containers.DenseAxisArray([0.50 -0.50; 0.80 -0.80], lines_empty, zone_pairs_empty)

        sets_empty = POMATWO.Sets(
            N=["N1","N2"], L=lines_empty, Z=["Z1","Z2"], P=String[], S=String[],
            DC=String[], DISP=String[], NDISP=String[],
            NTC=Tuple{String,String}[], PRS=String[], PRS_STO=String[],
            FBCCR=String[]   # no flow-based zones defined
        )
        params_empty = POMATWO.Parameters(
            sets=sets_empty,
            node2zone=Dict("N1"=>"Z1","N2"=>"Z2"),
            line_start=Dict("L1"=>"N1","L2"=>"N1"),
            line_end  =Dict("L1"=>"N2","L2"=>"N2")
        )

        POMATWO.define_cne!(params_empty, PTDFzz_empty; threshold=0.05)
        @test isempty(params_empty.cne)   # no FBCCR zones → no CNEs possible
    end

    @testset "define_cne!: PTDF threshold still applies for FBCCR-connected lines" begin
        lines_thresh = ["L_high","L_low"]
        zone_pairs_thresh = [("Z1","Z2"),("Z2","Z1")]
        PTDFzz_thresh = JuMP.Containers.DenseAxisArray([0.20 -0.20; 0.03 -0.03], lines_thresh, zone_pairs_thresh)

        sets_thresh = POMATWO.Sets(
            N=["N1","N2"], L=lines_thresh, Z=["Z1","Z2"], P=String[], S=String[],
            DC=String[], DISP=String[], NDISP=String[],
            NTC=Tuple{String,String}[], PRS=String[], PRS_STO=String[],
            FBCCR=["Z1","Z2"]
        )
        params_thresh = POMATWO.Parameters(
            sets=sets_thresh,
            node2zone=Dict("N1"=>"Z1","N2"=>"Z2"),
            line_start=Dict("L_high"=>"N1","L_low"=>"N1"),
            line_end  =Dict("L_high"=>"N2","L_low"=>"N2")
        )

        POMATWO.define_cne!(params_thresh, PTDFzz_thresh; threshold=0.10)

        @test "L_high" in params_thresh.cne   # passes both FBCCR and threshold checks
        @test "L_low"  ∉ params_thresh.cne    # in FBCCR zone but PTDF too low
        @test length(params_thresh.cne) == 1
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

    @testset "calc_ram: reference-flow F0 sign coherence (reproduction invariant)" begin
        # This is the sign test the 70%-rule testset above cannot make: it uses a
        # GENUINE DC power flow (lineflow = PTDFn·netinput) so the sign relationship
        # between the two f0 terms is real, and checks the defining property of the
        # linearization intercept F0:
        #     F0 + Σ_z PTDFz[l,z]·NP_export[z]  ==  physical flow  == -lineflow
        # with NP_export = -netinput_ac. The buggy code (f0 = +lineflow - ΣPTDFz·NP)
        # double-counts the commercial exchange and fails this; the fix passes it.
        #
        # 4 nodes, 2 zones (2 nodes each), 2 lines. Flat GSK ⇒ PTDFz[l,z] = mean of the
        # zone's nodal PTDF. L1 carries loop flow (|F0| > f_max, which is LEGITIMATE —
        # F0 is a linearization intercept, not a physical flow, so |F0| ≤ f_max is NOT
        # asserted). L2 is purely commercial ⇒ F0 = 0.
        nodes = ["N1", "N2", "N3", "N4"]
        zones = ["Z1", "Z2"]
        lines = ["L1", "L2"]
        T = 1:1
        node_zone_map = Dict("N1"=>"Z1", "N2"=>"Z1", "N3"=>"Z2", "N4"=>"Z2")

        sets = POMATWO.Sets(
            N=nodes, L=lines, Z=zones, P=String[], S=String[],
            DC=String[], DISP=String[], NDISP=String[],
            NTC=Tuple{String,String}[], PRS=String[], PRS_STO=String[]
        )
        params = POMATWO.Parameters(
            sets=sets,
            node2zone=node_zone_map,
            nodes_in_zone=Dict("Z1"=>["N1","N2"], "Z2"=>["N3","N4"]),
            acline_capacity=Dict("L1"=>8.0, "L2"=>100.0),   # tiny L1 cap: |F0|>f_max
            cne=copy(lines)
        )

        # Nodal PTDF (l×n) and the flat-GSK zonal PTDF (l×z = zonal mean).
        PTDFn_data = [ 0.4  0.1  -0.2  -0.3;    # L1 → loop flow (nodes differ from zone mean)
                       0.3  0.3  -0.3  -0.3 ]   # L2 → zone-uniform ⇒ purely commercial
        PTDFn = JuMP.Containers.DenseAxisArray(PTDFn_data, lines, nodes)
        PTDFz_data = [ 0.25 -0.25;   # L1: mean(0.4,0.1)=0.25 ; mean(-0.2,-0.3)=-0.25
                       0.30 -0.30 ]  # L2: mean(0.3,0.3)=0.30 ; mean(-0.3,-0.3)=-0.30
        PTDFz = JuMP.Containers.DenseAxisArray(PTDFz_data, lines, zones)
        PTDFzz = POMATWO.zone_to_zone_ptdf(PTDFz; exclude_self=true)

        # Import-positive nodal injections (load+charge-gen); balanced. NP is export-positive.
        netinput = [40.0; -10.0; -5.0; -25.0]   # N1..N4
        netinput_ac = JuMP.Containers.DenseAxisArray(reshape(netinput, 4, 1), nodes, collect(T))
        NP = Dict("Z1" => -(40.0 - 10.0), "Z2" => -(-5.0 - 25.0))   # -30, +30

        # Genuine DC flow: lineflow = PTDFn·netinput (this is what makes the sign real).
        lineflow = PTDFn_data * netinput
        @test lineflow ≈ [23.5, 18.0]
        lineflows = JuMP.Containers.DenseAxisArray(reshape(lineflow, 2, 1), lines, collect(T))
        basecase = Dict(:lineflows => lineflows, :netinput_ac => netinput_ac)

        minRAM, FRM = 0.7, 0.1
        ram = POMATWO.calc_ram(params, basecase, PTDFz, PTDFzz, PTDFn, T; minRAM=minRAM, FRM=FRM)

        for (i, l) in enumerate(lines)
            fmax       = params.acline_capacity[l]
            commercial = sum(PTDFz[l, z] * NP[z] for z in zones)     # Σ PTDFz·NP_export
            f0_correct = -lineflow[i] - commercial                   
            f0_buggy   =  lineflow[i] - commercial                   

            # Recover the f0 the model actually used from RAM_pos. init_pos is not
            # floored here (checked below), so RAM_pos = f_max - f0 - FRM·f_max.
            init_pos_floor = minRAM * fmax
            @test fmax - f0_correct - FRM * fmax ≥ init_pos_floor - 1e-9   # AMR inactive on pos
            f0_model = fmax - FRM * fmax - ram[l, T[1], "pos"]

            @test f0_model ≈ f0_correct atol=1e-9        # model uses the corrected sign
            @test !isapprox(f0_model, f0_buggy; atol=1e-6)   # and NOT the buggy sign

            # Reproduction invariant (f_max-free): linearization passes through the
            # basecase net position and reproduces the basecase physical flow.
            @test f0_model + commercial ≈ -lineflow[i] atol=1e-9
        end

        # L1: loop flow — F0 = -23.5 - (-15) = -8.5, magnitude 8.5 > f_max = 8 (legit).
        @test (8.0 - 0.1*8.0 - ram["L1", 1, "pos"]) ≈ -8.5 atol=1e-9
        @test ram["L1", 1, "pos"] ≈ 15.7 atol=1e-9      # = 8 - (-8.5) - 0.8, NOT clamped to f_max
        @test ram["L1", 1, "neg"] ≈ -5.6 atol=1e-9      # floored to -minRAM·f_max
        # L2: purely commercial — F0 = -18 - (-18) = 0 ⇒ symmetric RAM = ±(f_max - FRM·f_max).
        @test (100.0 - 10.0 - ram["L2", 1, "pos"]) ≈ 0.0 atol=1e-9
        @test ram["L2", 1, "pos"] ≈ 90.0 atol=1e-9
        @test ram["L2", 1, "neg"] ≈ -90.0 atol=1e-9
    end

    @testset "calc_ram: AMR floor active vs inactive (both directions)" begin
        # Isolate the minRAM-floor (AMR) logic with exact hand values. One node per
        # zone, shared PTDFz and netinput ⇒ Σ PTDFz·NP = -20 on every line; per-line
        # lineflow sets f0 = -lineflow - (-20) = 20 - lineflow. f_max = 100, FRM = 0.1,
        # minRAM = 0.7 ⇒ floor = ±70.
        #   L_A: f0 =   0  → init_pos=90, init_neg=-90  → AMR inactive both sides
        #   L_B: f0 =  40  → init_pos=50 (<70) floored, init_neg=-130 inactive
        #   L_C: f0 = -40  → init_pos=130 inactive,     init_neg=-50 (>-70) floored
        nodes = ["N1", "N2"]
        zones = ["Z1", "Z2"]
        lines = ["L_A", "L_B", "L_C"]
        T = 1:1
        node_zone_map = Dict("N1"=>"Z1", "N2"=>"Z2")

        sets = POMATWO.Sets(
            N=nodes, L=lines, Z=zones, P=String[], S=String[],
            DC=String[], DISP=String[], NDISP=String[],
            NTC=Tuple{String,String}[], PRS=String[], PRS_STO=String[]
        )
        params = POMATWO.Parameters(
            sets=sets,
            node2zone=node_zone_map,
            nodes_in_zone=Dict("Z1"=>["N1"], "Z2"=>["N2"]),
            acline_capacity=Dict("L_A"=>100.0, "L_B"=>100.0, "L_C"=>100.0),
            cne=copy(lines)
        )

        PTDFz_data = [0.5 -0.5; 0.5 -0.5; 0.5 -0.5]
        PTDFz = JuMP.Containers.DenseAxisArray(PTDFz_data, lines, zones)
        PTDFzz = POMATWO.zone_to_zone_ptdf(PTDFz; exclude_self=true)
        PTDFn = PTDFz   # unused by calc_ram; shape-compatible

        netinput = [20.0; -20.0]   # NP_Z1 = -20, NP_Z2 = +20 ⇒ Σ PTDFz·NP = -20 (all lines)
        netinput_ac = JuMP.Containers.DenseAxisArray(reshape(netinput, 2, 1), nodes, collect(T))
        # lineflow chosen per line to hit target f0 = 20 - lineflow: 20→0, -20→40, 60→-40
        lineflow = [20.0; -20.0; 60.0]
        lineflows = JuMP.Containers.DenseAxisArray(reshape(lineflow, 3, 1), lines, collect(T))
        basecase = Dict(:lineflows => lineflows, :netinput_ac => netinput_ac)

        ram = POMATWO.calc_ram(params, basecase, PTDFz, PTDFzz, PTDFn, T; minRAM=0.7, FRM=0.1)

        # L_A: f0=0, AMR inactive both sides (init within [floor, ...]).
        @test ram["L_A", 1, "pos"] ≈ 90.0 atol=1e-9    # init_pos, NOT the 70 floor
        @test ram["L_A", 1, "neg"] ≈ -90.0 atol=1e-9   # init_neg, NOT the -70 floor
        # L_B: f0=40, positive side floored to +70, negative side inactive.
        @test ram["L_B", 1, "pos"] ≈ 70.0 atol=1e-9    # AMR lifts init_pos=50 up to floor
        @test ram["L_B", 1, "neg"] ≈ -130.0 atol=1e-9  # init_neg, AMR inactive
        # L_C: f0=-40, positive side inactive, negative side floored to -70.
        @test ram["L_C", 1, "pos"] ≈ 130.0 atol=1e-9   # init_pos, AMR inactive
        @test ram["L_C", 1, "neg"] ≈ -70.0 atol=1e-9   # AMR lifts init_neg=-50 to -floor
    end

    @testset "GSK Strategy: GenLoadGSK trait + static fallback" begin
        @test POMATWO.is_time_dependent(POMATWO.GenLoadGSK())
        @test !POMATWO.is_time_dependent(POMATWO.FlatGSK())
        @test !POMATWO.is_time_dependent(POMATWO.GmaxGSK())
        @test !POMATWO.is_time_dependent(POMATWO.DispOnlyGSK())

        nodes = ["N1", "N2", "N3"]
        zones = ["Z1", "Z2"]
        node_zone_map = Dict("N1" => "Z1", "N2" => "Z1", "N3" => "Z2")
        sets = POMATWO.Sets(
            N=nodes, L=String[], Z=zones, P=["P1", "P2", "P3"], S=String[],
            DC=String[], DISP=String[], NDISP=String[],
            NTC=Tuple{String,String}[], PRS=String[], PRS_STO=String[]
        )
        params = POMATWO.Parameters(
            sets=sets,
            node2zone=node_zone_map,
            plant2node=Dict("P1" => "N1", "P2" => "N2", "P3" => "N3"),
            gmax=Dict("P1" => 100.0, "P2" => 200.0, "P3" => 50.0),
            avail=Dict("P1" => POMATWO.HourlyProfile([0.5, 0.5]),
                       "P3" => POMATWO.FixedProfile(0.8)),
            nodal_load=Dict("N1" => POMATWO.FixedProfile(30.0),
                            "N2" => POMATWO.HourlyProfile([10.0, 20.0]))
        )

        # Static fallback is load-only (no capacity terms — gmax/avail must not
        # leak in): N1 = 30 ; N2 = mean([10,20]) = 15 ; N3 = 0 (no load)
        # A plain build_gsk call warns that this is not the per-timestep GLSK
        G = @test_logs (:warn,) match_mode=:any POMATWO.build_gsk(params, POMATWO.GenLoadGSK())
        @test G["N1", "Z1"] ≈ 30 / 45
        @test G["N2", "Z1"] ≈ 15 / 45
        @test G["N3", "Z2"] == 0.0   # zone without load → empty (default :zero)

        G_flat = POMATWO.build_gsk(params, POMATWO.GenLoadGSK(); normalize_empty=:flat)
        @test G_flat["N3", "Z2"] ≈ 1.0
    end

    @testset "build_gsk_timeseries: per-timestep GLSK from basecase" begin
        nodes = ["N1", "N2", "N3"]
        zones = ["Z1", "Z2"]
        node_zone_map = Dict("N1" => "Z1", "N2" => "Z1", "N3" => "Z2")
        sets = POMATWO.Sets(
            N=nodes, L=String[], Z=zones, P=String[], S=String[],
            DC=String[], DISP=String[], NDISP=String[],
            NTC=Tuple{String,String}[], PRS=String[], PRS_STO=String[]
        )
        params = POMATWO.Parameters(
            sets=sets,
            node2zone=node_zone_map,
            nodal_load=Dict("N1" => POMATWO.HourlyProfile([30.0, 60.0]),
                            "N2" => POMATWO.FixedProfile(10.0))
            # N3 has no load profile → load = 0
        )

        T = 1:2
        netinput_data = [20.0 -10.0; 5.0 15.0; -25.0 -5.0]   # nodes × T
        netinput_ac = JuMP.Containers.DenseAxisArray(netinput_data, nodes, collect(T))

        G = POMATWO.build_gsk_timeseries(params, POMATWO.GenLoadGSK(), netinput_ac, T)

        @test G isa JuMP.Containers.DenseAxisArray
        @test size(G) == (3, 2, 2)
        @test collect(axes(G, 1)) == nodes
        @test collect(axes(G, 2)) == zones
        @test collect(axes(G, 3)) == collect(T)

        # netinput_ac is import-positive → gen = load − netinput
        # t=1: N1 load=30, gen=30−20=10  → w=40 ; N2 load=10, gen=10−5=5 → w=15
        #      N3 load=0,  gen=0−(−25)=25 → w=25
        @test G["N1", "Z1", 1] ≈ 40 / 55
        @test G["N2", "Z1", 1] ≈ 15 / 55
        @test G["N3", "Z2", 1] ≈ 1.0

        # t=2: N1 load=60, gen=60−(−10)=70 → w=130 ; N2 load=10, gen=10−15=−5 → w=15
        #      N3 load=0,  gen=0−(−5)=5    → w=5
        @test G["N1", "Z1", 2] ≈ 130 / 145
        @test G["N2", "Z1", 2] ≈ 15 / 145
        @test G["N3", "Z2", 2] ≈ 1.0

        # GSK differs across timesteps and every zone column sums to 1 per t
        @test G["N1", "Z1", 1] != G["N1", "Z1", 2]
        for t in T, z in zones
            @test sum(G[n, z, t] for n in nodes if node_zone_map[n] == z) ≈ 1.0
        end
        # Cross-zone entries stay 0
        @test G["N1", "Z2", 1] == 0.0
        @test G["N3", "Z1", 2] == 0.0
    end

    @testset "zonal_ptdf: time-dependent GSK (n×z×t) → PTDFz (l×z×t)" begin
        lines = ["L1", "L2"]
        nodes = ["N1", "N2", "N3"]
        zones = ["Z1", "Z2"]
        T = 1:2

        PTDF_data = [0.6 0.2 -0.4; 0.2 0.6 -0.4]
        PTDF = JuMP.Containers.DenseAxisArray(PTDF_data, lines, nodes)

        GSK_data = zeros(3, 2, 2)
        GSK_data[:, 1, 1] = [0.8, 0.2, 0.0]   # Z1 @ t=1
        GSK_data[:, 2, 1] = [0.0, 0.0, 1.0]   # Z2 @ t=1
        GSK_data[:, 1, 2] = [0.5, 0.5, 0.0]   # Z1 @ t=2
        GSK_data[:, 2, 2] = [0.0, 0.0, 1.0]   # Z2 @ t=2
        GSK = JuMP.Containers.DenseAxisArray(GSK_data, nodes, zones, collect(T))

        PTDFz = POMATWO.zonal_ptdf(PTDF, GSK)

        @test size(PTDFz) == (2, 2, 2)
        for l in lines, z in zones, t in T
            expected = sum(PTDF[l, n] * GSK[n, z, t] for n in nodes)
            @test PTDFz[l, z, t] ≈ expected atol=1e-4
        end
        # time-dependence propagates: Z1 column changes between t=1 and t=2
        @test PTDFz["L1", "Z1", 1] != PTDFz["L1", "Z1", 2]

        # _ptdfz accessor resolves both static and time-dependent matrices
        static = JuMP.Containers.DenseAxisArray([0.1 0.2; 0.3 0.4], lines, zones)
        @test POMATWO._ptdfz(static, "L1", "Z2", 1) == 0.2
        @test POMATWO._ptdfz(static, "L1", "Z2", 2) == 0.2   # t ignored
        @test POMATWO._ptdfz(PTDFz, "L1", "Z1", 1) == PTDFz["L1", "Z1", 1]
        @test POMATWO._ptdfz(PTDFz, "L1", "Z1", 2) == PTDFz["L1", "Z1", 2]
    end

    @testset "calc_fbmc_params: time-dependent GenLoadGSK end-to-end" begin
        nodes = ["N1", "N2", "N3"]
        zones = ["Z1", "Z2"]
        lines = ["L1", "L2"]
        T = 1:2
        node_zone_map = Dict("N1" => "Z1", "N2" => "Z1", "N3" => "Z2")

        sets = POMATWO.Sets(
            N=nodes, L=lines, Z=zones, P=String[], S=String[],
            DC=String[], DISP=String[], NDISP=String[],
            NTC=Tuple{String,String}[], PRS=String[], PRS_STO=String[],
            FBCCR=zones
        )
        params = POMATWO.Parameters(
            sets=sets,
            node2zone=node_zone_map,
            nodes_in_zone=Dict("Z1" => ["N1", "N2"], "Z2" => ["N3"]),
            nodal_load=Dict("N1" => POMATWO.HourlyProfile([30.0, 60.0]),
                            "N2" => POMATWO.FixedProfile(10.0)),
            acline_capacity=Dict("L1" => 100.0, "L2" => 100.0),
            line_start=Dict("L1" => "N1", "L2" => "N2"),
            line_end=Dict("L1" => "N3", "L2" => "N3"),
            ptdf=Dict(("L1", "N1") => 0.6, ("L1", "N2") => 0.2, ("L1", "N3") => -0.4,
                      ("L2", "N1") => 0.2, ("L2", "N2") => 0.6, ("L2", "N3") => -0.4)
        )

        netinput_data = [20.0 -10.0; 5.0 15.0; -25.0 -5.0]
        lineflow_data = [10.0 5.0; 8.0 4.0]
        basecase = Dict(
            :netinput_ac => JuMP.Containers.DenseAxisArray(netinput_data, nodes, collect(T)),
            :lineflows   => JuMP.Containers.DenseAxisArray(lineflow_data, lines, collect(T)),
        )

        fb = POMATWO.calc_fbmc_params(POMATWO.GenLoadGSK(), params, basecase, T)

        # 3D GSK/PTDFz, per-t zone columns normalized
        @test ndims(fb[:GSK].data) == 3
        @test ndims(fb[:PTDFz].data) == 3
        @test collect(axes(fb[:GSK], 3)) == collect(T)
        for t in T, z in zones
            @test sum(fb[:GSK][n, z, t] for n in nodes if node_zone_map[n] == z) ≈ 1.0
        end

        # PTDFz varies over time (load/injection pattern differs between t=1 and t=2)
        @test fb[:PTDFz].data[:, 1, 1] != fb[:PTDFz].data[:, 1, 2]

        # CNE screening ran and RAM has the (cne × T × direction) shape with finite values
        @test !isempty(params.cne)
        @test size(fb[:RAM]) == (length(params.cne), length(T), 2)
        @test all(isfinite.(fb[:RAM].data))

        # F0 and the 70%-rule fractions are exposed alongside RAM so they can be
        # persisted (:RAM result table). The rule must be reproducible from
        # (F0, fmax, FRM, minRAM) alone — that is what the persisted table promises.
        @test size(fb[:F0]) == (length(params.cne), length(T))
        @test all(isfinite.(fb[:F0].data))
        @test fb[:minRAM] == 0.7
        @test fb[:FRM] == 0.1
        for l in params.cne, t in T
            fmax = params.acline_capacity[l]
            @test fb[:RAM][l, t, "pos"] ≈
                  max(fmax - fb[:F0][l, t] - fb[:FRM] * fmax, fb[:minRAM] * fmax)
            @test fb[:RAM][l, t, "neg"] ≈
                  min(-fmax - fb[:F0][l, t] + fb[:FRM] * fmax, -fb[:minRAM] * fmax)
        end

        # Static strategy still returns 2D matrices (regression)
        empty!(params.cne)
        fb_static = POMATWO.calc_fbmc_params(POMATWO.FlatGSK(), params, basecase, T)
        @test ndims(fb_static[:PTDFz].data) == 2
        @test ndims(fb_static[:GSK].data) == 2
    end
end
