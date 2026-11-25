"""
Guards the one-objective-per-OptiNode invariant.

`@objective` REPLACES a node's objective, it does not add to it. Any builder that
contributes more than one cost term must accumulate them and call `@objective` exactly once.
The day-ahead non-dispatchable builder used to call `@objective` three times (curtailment
cost, historical-generation slack, min-generation slack), silently dropping all but the last
term. Nothing in the model errors when that happens — the run just optimizes the wrong
objective — so this is asserted directly on the built node.
"""

function test_objectives()
    @testset "Objective composition" begin
        params = load_data(cases["case 3"][:data_files])

        # Both optional profiles are keyed by plant type; "wind" is the non-dispatchable
        # type in case 3. Neither is exercised by any example, so set them up here.
        @test params.nondispatchable == ["wind"]
        params.historical_generation["wind"] = POMATWO.FixedProfile(100.0)
        params.min_generation["wind"] = POMATWO.FixedProfile(50.0)

        T = 1:4

        # Build the day-ahead stage without solving it, and return the non-dispatchable
        # node together with the objective that ended up on it.
        build_ndisp(tmpdir, name; setup_kwargs...) = begin
            setup = ModelSetup(;
                TimeHorizon     = TimeHorizon(stop=4),
                MarketType      = ZonalMarket(),
                ProsumerSetup   = NoProsumer(),
                RedispatchSetup = NoRedispatch(),
                setup_kwargs...,
            )
            mr = ModelRun(params, setup, HiGHS.Optimizer;
                resultdir=tmpdir, scenarioname=name, overwrite=true)
            ctx = Dict{Symbol,Any}()
            state = POMATWO.init_state(POMATWO.DayAhead, mr, T, ctx)
            node = POMATWO.SubRun(mr, state, ctx).vars[:ndisp]
            return node, JuMP.objective_function(node)
        end

        # Only non-zero coefficients count: whether JuMP keeps zero terms is not our concern.
        nonzero_terms(obj) = count(!iszero, values(obj.terms))

        mktempdir() do tmpdir
            with_logger(NullLogger()) do
                # A non-zero curtailment cost, so all three cost terms are visible at once.
                node, obj = build_ndisp(tmpdir, "obj_composition"; curtailment_cost = 50.0)
                for t in T
                    @test JuMP.coefficient(obj, node[:CU]["w3", t]) ≈ 50.0
                    @test JuMP.coefficient(obj, node[:HISTORICAL_INF]["wind", t]) ≈ 1000.0
                    @test JuMP.coefficient(obj, node[:MINGEN_INF]["wind", t]) ≈ 1000.0
                end
                # 4 hours x (1 curtailment + 1 historical slack + 1 mingen slack).
                # A dropped term would show up here as a shorter objective.
                @test nonzero_terms(obj) == 12

                # Default: curtailment is free, the two slack terms are unaffected.
                @test ModelSetup(TimeHorizon = TimeHorizon()).curtailment_cost == 0.0
                node, obj = build_ndisp(tmpdir, "obj_default")
                for t in T
                    @test JuMP.coefficient(obj, node[:CU]["w3", t]) == 0.0
                    @test JuMP.coefficient(obj, node[:HISTORICAL_INF]["wind", t]) ≈ 1000.0
                    @test JuMP.coefficient(obj, node[:MINGEN_INF]["wind", t]) ≈ 1000.0
                end
                @test nonzero_terms(obj) == 8
            end
        end
    end
end
