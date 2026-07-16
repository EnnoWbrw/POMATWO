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

        mktempdir() do tmpdir
            with_logger(NullLogger()) do
                setup = ModelSetup(
                    TimeHorizon     = TimeHorizon(stop=4),
                    MarketType      = ZonalMarket(),
                    ProsumerSetup   = NoProsumer(),
                    RedispatchSetup = NoRedispatch(),
                )
                mr = ModelRun(params, setup, HiGHS.Optimizer;
                    resultdir=tmpdir, scenarioname="obj_composition", overwrite=true)

                # Build the day-ahead stage without solving it, and inspect the objective
                # that ended up on the non-dispatchable node.
                T = 1:4
                ctx = Dict{Symbol,Any}()
                state = POMATWO.init_state(POMATWO.DayAhead, mr, T, ctx)
                sr = POMATWO.SubRun(mr, state, ctx)

                node = sr.vars[:ndisp]
                obj = JuMP.objective_function(node)

                CU = node[:CU]
                HISTORICAL_INF = node[:HISTORICAL_INF]
                MINGEN_INF = node[:MINGEN_INF]

                # All three cost terms must be present simultaneously.
                for t in T
                    @test JuMP.coefficient(obj, CU["w3", t]) ≈ 50.0
                    @test JuMP.coefficient(obj, HISTORICAL_INF["wind", t]) ≈ 1000.0
                    @test JuMP.coefficient(obj, MINGEN_INF["wind", t]) ≈ 1000.0
                end

                # 4 hours x (1 curtailment + 1 historical slack + 1 mingen slack).
                # A dropped term would show up here as a shorter objective.
                @test length(obj.terms) == 12
            end
        end
    end
end
