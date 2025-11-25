using Test
using POMATWO

# Require the renamed function to exist (non-bang only)
@assert isdefined(POMATWO, :zone_to_zone_ptdf) "Expected POMATWO.zone_to_zone_ptdf to be defined"

function test_zonal_ptdf()
    @testset "GSK: basic proportional split (flat zones)" begin
        # 2 zones, 4 nodes (n=4, z=2)
        # Mapping: node1,node2 → Z1 ; node3,node4 → Z2
        node_to_zone = [1, 1, 2, 2]
        weights      = [10, 30, 50, 10]

        # Z1 total = 40 → node1=0.25, node2=0.75
        # Z2 total = 60 → node3=5/6, node4=1/6
        G = POMATWO.build_gsk(node_to_zone; weights, normalize_empty=:zero)
        @test size(G) == (4, 2)
        @test all(abs.(sum(G; dims=1) .- 1) .< 1e-12)

        @test G[1,1] ≈ 0.25
        @test G[2,1] ≈ 0.75
        @test G[3,2] ≈ 50/60
        @test G[4,2] ≈ 10/60

        # each row contributes only to its zone's column
        for i in 1:4
            nz = findall(!iszero, G[i, :])
            @test length(nz) ≤ 1
            if !isempty(nz)
                @test nz[1] == node_to_zone[i]
            end
        end
    end

    @testset "zonal_ptdf: PTDF(l×n) * G(n×z) = PTDFz(l×z)" begin
        l, n, z = 3, 4, 2
        # Deterministic tiny PTDF like in omission tests
        PTDF = reshape(collect(1.0:(l*n)), l, n) .* 1e-3
        node_to_zone = [1, 1, 2, 2]
        weights      = [10, 30, 50, 10]
        G = POMATWO.build_gsk(node_to_zone; weights, normalize_empty=:zero)

        PTDFz = POMATWO.zonal_ptdf(PTDF, G)
        @test size(PTDFz) == (l, z)
        @test PTDFz[:, 1] ≈ PTDF * G[:, 1]
        @test PTDFz[:, 2] ≈ PTDF * G[:, 2]
    end

    @testset "zone→zone PTDF (export→import) from zonal PTDF" begin
        # Tiny l×z zonal PTDF; 
        PTDFz = [
            0.10  0.40;   # line1 for (Z1,Z2)
            0.30  0.20;   # line2
            0.05  0.15    # line3
        ]
        zones = [:Z1, :Z2]

        # (Z1→Z2) and (Z2→Z1) columns expected
        PTDFzz, pairs = POMATWO.zone_to_zone_ptdf(PTDFz; zones=zones, exclude_self=true)
        @test size(PTDFzz) == (3, 2)
        @test length(pairs) == 2

        # Ordering used here: importer-major then exporter
        # pairs = (Z1→Z2), (Z2→Z1)
        @test pairs[1] == (:Z1, :Z2)
        @test pairs[2] == (:Z2, :Z1)

        # Column for (Z1→Z2) = PTDFz[:, Z2] - PTDFz[:, Z1]
        @test PTDFzz[:, 1] ≈ (PTDFz[:, 2] .- PTDFz[:, 1])
        # Column for (Z2→Z1) = PTDFz[:, Z1] - PTDFz[:, Z2]
        @test PTDFzz[:, 2] ≈ (PTDFz[:, 1] .- PTDFz[:, 2])
    end

    @testset "Empty-zone behavior (normalize_empty = :flat)" begin
        # 3 zones, 5 nodes; make zone 2 empty via zero weights
        node_to_zone = [1, 2, 2, 3, 3]
        weights      = [5, 0, 0, 20, 20]
        G = POMATWO.build_gsk(node_to_zone; weights, normalize_empty=:flat)
        @test size(G) == (5, 3)
        @test G[2,2] ≈ 0.5 && G[3,2] ≈ 0.5  # uniform split within empty zone's members
    end
end
