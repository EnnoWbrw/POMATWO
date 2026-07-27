"""
Tests for the redispatch stage:
  - bidirectional redispatch of non-dispatchable generators (GEN_UP recalls day-ahead
    curtailment, GEN_DOWN curtails further)
  - the configurable redispatch cost fields on DCLF
  - prosumer plants stay exempt from redispatch

Uses "case 3" (test_data_3_nodes_res_recall), a purpose-built network in which the only way
to relieve the congested line is to recall curtailed wind. See cases.jl for the derivation.
"""

function test_redispatch()
    @testset "Redispatch" begin
        solver = HiGHS.Optimizer
        logger = NullLogger()

        params = load_data(cases["case 3"][:data_files])
        expected = cases["case 3"][:expected]

        run_redisp(tmpdir, name, rd) = with_logger(logger) do
            setup = ModelSetup(
                TimeHorizon     = TimeHorizon(stop=4),
                MarketType      = ZonalMarket(),
                ProsumerSetup   = NoProsumer(),
                RedispatchSetup = rd,
            )
            mr = ModelRun(params, setup, solver;
                resultdir=tmpdir, scenarioname=name, overwrite=true)
            POMATWO.run(mr)
            DataFiles(joinpath(tmpdir, name))
        end

        ndisp_rows(r) = filter(row -> row.index in params.sets.NDISP, r.REDISP)
        disp_rows(r) = filter(row -> row.index in params.sets.DISP, r.REDISP)

        # =================================================================
        @testset "DCLF cost fields" begin
            # Defaults, and both constructors still work unchanged.
            d = DCLF()
            @test d isa DCLF{PhaseAngle}
            @test d.disp_cost == 150.0
            @test d.res_up_cost == 1.0
            @test d.res_down_cost == 150.0
            @test d.sto_cost == 150.0

            @test DCLF(PhaseAngle) isa DCLF{PhaseAngle}
            @test DCLF(POMATWO.PTDF) isa DCLF{POMATWO.PTDF}

            # Costs are overridable on both constructors.
            @test DCLF(; res_up_cost = 0.0).res_up_cost == 0.0
            @test DCLF(POMATWO.PTDF; disp_cost = 42.0).disp_cost == 42.0
            @test DCLF(POMATWO.PTDF; disp_cost = 42.0) isa DCLF{POMATWO.PTDF}
        end

        mktempdir() do tmpdir
            # Default: non-dispatchables may be recalled (res_up_cost = 1.0).
            results = run_redisp(tmpdir, "rd_recall_on", DCLF())
            # Recall priced out of the market: reproduces the pre-change, downward-only
            # behaviour of non-dispatchable redispatch.
            results_no_recall =
                run_redisp(tmpdir, "rd_recall_off", DCLF(; res_up_cost = 1e6))

            # =================================================================
            @testset "day-ahead curtails wind (the precondition)" begin
                for (plant, gen) in expected[:da_gen]
                    rows = filter(r -> r.index == plant, results.GEN)
                    @test all(isapprox.(rows.GEN, gen, atol=1e-6))
                end
                for (plant, cu) in expected[:da_cu]
                    rows = filter(r -> r.index == plant, results.GEN)
                    @test all(isapprox.(rows.CU, cu, atol=1e-6))
                end
            end

            # =================================================================
            @testset "non-dispatchable redispatch is bidirectional" begin
                nd = ndisp_rows(results)
                @test !isempty(nd)

                # Recall is bounded by what was actually curtailed in the day-ahead, so it
                # can never exceed the available potential.
                @test all(nd.GEN_UP .>= -1e-8)
                @test all(nd.GEN_DOWN .>= -1e-8)
                @test all(nd.GEN_UP .<= nd.max_up .+ 1e-8)
                @test all(nd.GEN_DOWN .<= nd.gen .+ 1e-8)

                # Redispatched feed-in and curtailment are consistent with the up/down pair.
                @test all(isapprox.(nd.GEN_REDISP, nd.gen .+ nd.GEN_UP .- nd.GEN_DOWN, atol=1e-6))
                @test all(isapprox.(nd.CU_REDISP, nd.max_up .- nd.GEN_UP .+ nd.GEN_DOWN, atol=1e-6))
                @test all(nd.CU_REDISP .>= -1e-8)
                @test all(nd.GEN_REDISP .>= -1e-8)

                # max_up is the day-ahead curtailment.
                for row in eachrow(nd)
                    da = only(filter(r -> r.index == row.index && r.Time == row.Time, results.GEN))
                    @test row.max_up ≈ da.CU atol=1e-6
                    @test row.gen ≈ da.GEN atol=1e-6
                end
            end

            # =================================================================
            @testset "recall relieves congestion instead of shedding load" begin
                nd = ndisp_rows(results)
                dp = disp_rows(results)

                # Wind is recalled, gas comes down by the same amount.
                @test all(isapprox.(nd.GEN_UP, expected[:res_recall], atol=1e-6))
                @test all(isapprox.(dp.GEN_DOWN, expected[:disp_down], atol=1e-6))
                @test sum(nd.GEN_DOWN) ≈ 0.0 atol=1e-6
                @test sum(dp.GEN_UP) ≈ 0.0 atol=1e-6

                # No infeasibility slack: the congestion is fully resolved by redispatch.
                @test sum(results.NodalMarketRedispBalance.LL) ≈ 0.0 atol=1e-6
                @test sum(results.NodalMarketRedispBalance.CU) ≈ 0.0 atol=1e-6

                # Without recall the same congestion can only be resolved by shedding load.
                nd_off = ndisp_rows(results_no_recall)
                @test sum(nd_off.GEN_UP) ≈ 0.0 atol=1e-6
                @test sum(results_no_recall.NodalMarketRedispBalance.LL) > 1e-6
            end

            # =================================================================
            @testset "recall is reported through GEN_UP/GEN_DOWN" begin
                # get_redispatch_by_type_node must now see the renewable adjustment, which
                # it silently missed while ndisp GEN_UP/GEN_DOWN were hardcoded to zero.
                diff = get_redispatch_by_type_node(results)
                wind = filter(r -> r.type == "wind", diff)
                @test !isempty(wind)
                @test all(wind.difference .> 1e-6)
                @test all(isapprox.(wind.difference, expected[:res_recall], atol=1e-6))
            end
        end

        # =================================================================
        @testset "prosumer plants are exempt from redispatch" begin
            params_prs = load_data(cases["case 2"][:data_files])

            mktempdir() do tmpdir
                results = with_logger(logger) do
                    setup = ModelSetup(
                        TimeHorizon     = TimeHorizon(stop=4),
                        MarketType      = ZonalMarket(),
                        ProsumerSetup   = ProsumerOptimization(sell_price=80.0, buy_price=250.0, retail_type=:buy_price),
                        RedispatchSetup = DCLF(),
                    )
                    mr = ModelRun(params_prs, setup, solver;
                        resultdir=tmpdir, scenarioname="rd_prosumer", overwrite=true)
                    POMATWO.run(mr)
                    DataFiles(joinpath(tmpdir, "rd_prosumer"))
                end

                # Prosumers represent aggregated household capacity, not TSO-dispatchable
                # assets: they must not show up as redispatchable units at all.
                @test !isempty(params_prs.sets.PRS)
                @test !any(p in params_prs.sets.PRS for p in results.REDISP.index)
            end
        end
    end
end
