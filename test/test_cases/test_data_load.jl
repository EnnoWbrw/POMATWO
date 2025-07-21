function test_data_load()
 @testset "Data Load" begin
    for (casename, case) in cases
        @testset "$casename" begin
            # Load data using data_files dict in this case
            params = load_data(case[:data_files])
            
           ex = case[:expected]
                if haskey(ex, :gmax_keys)
                    @test Set(keys(params.gmax)) == ex[:gmax_keys]
                end
                if haskey(ex, :gmax)
                    for p in params.sets.P
                        @test params.gmax[p] ≈ ex[:gmax][p]
                    end
                end
                if haskey(ex, :plant_type)
                    for (p, typ) in ex[:plant_type]
                        @test params.plant_type[p] == typ
                    end
                end
                if haskey(ex, :slack)
                    @test ex[:slack] in params.slack
                end
                if haskey(ex, :nodes_in_zone_DE)
                    @test length(params.plants_in_zone["DE"]) == ex[:nodes_in_zone_DE]
                end

                if haskey(ex,:prs_storage)
                    @test params.sets.PRS_STO == ex[:prs_storage][:name]
                    @test params.storage["prs_n2"] == ex[:prs_storage][:vol]
                    @test params.gmax_storage["prs_n2"] == ex[:prs_storage][:cap]
                end
            # If you add more fields to the case dict, just extend this section
        end
    end
end
end
