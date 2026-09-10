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

        # Zone `z`'s net position at `t`, aggregated from a nodal NETINPUT table. Both
        # NETINPUT and the day-ahead EXCHANGE are import-positive, so the two are directly
        # comparable — see the sign-convention section of CLAUDE.md.
        zone_np(ni, z, t) = sum(
            row.NETINPUT for row in eachrow(ni)
            if row.Time == t && row.index in params.nodes_in_zone[z];
            init = 0.0,
        )

        # =================================================================
        @testset "DCLF cost fields" begin
            # Defaults, and both constructors still work unchanged.
            d = DCLF()
            @test d isa DCLF{PhaseAngle}
            @test d.disp_cost == 150.0
            @test d.res_up_cost == 150.0
            @test d.res_down_cost == 150.0
            @test d.sto_cost == 500.0
            @test d.np_cost == 50000.0

            @test DCLF(PhaseAngle) isa DCLF{PhaseAngle}
            @test DCLF(POMATWO.PTDF) isa DCLF{POMATWO.PTDF}

            # Costs are overridable on both constructors.
            @test DCLF(; res_up_cost = 0.0).res_up_cost == 0.0
            @test DCLF(POMATWO.PTDF; disp_cost = 42.0).disp_cost == 42.0
            @test DCLF(POMATWO.PTDF; disp_cost = 42.0) isa DCLF{POMATWO.PTDF}
            @test DCLF(; np_cost = 1.0).np_cost == 1.0
            @test DCLF(POMATWO.PTDF; np_cost = 1.0).np_cost == 1.0
        end

        mktempdir() do tmpdir
            # Default: non-dispatchables may be recalled (res_up_cost = 150.0 — the same
            # price as dispatchable redispatch, so recall is an option, not a freebie).
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
        @testset "net positions pinned to day-ahead levels" begin
            @test DCLF().fix_net_positions == false
            @test DCLF(; fix_net_positions = true).fix_net_positions == true
            @test DCLF(; fix_net_positions = true) isa DCLF{PhaseAngle}
            @test DCLF(POMATWO.PTDF; fix_net_positions = true).fix_net_positions == true

            mktempdir() do tmpdir
                free   = run_redisp(tmpdir, "np_free",   DCLF())
                pinned = run_redisp(tmpdir, "np_pinned", DCLF(; fix_net_positions = true))

                dir_free = joinpath(tmpdir, "np_free")
                dir_pin  = joinpath(tmpdir, "np_pinned")

                T = 1:4
                Z = params.sets.Z

                # Redispatch has no EXCHANGE variable at all, so the day-ahead side comes
                # from the zonal DA table and the redispatch side from nodal NETINPUT.
                da_ex = DataFiles(dir_free, DayAhead).EXCHANGE
                da_np(z, t) = only(filter(r -> r.index == z && r.Time == t, da_ex)).EXCHANGE

                ni_free = DataFiles(dir_free, Redispatch).NETINPUT
                ni_pin  = DataFiles(dir_pin,  Redispatch).NETINPUT

                # The flag touches redispatch only — both runs clear the same day-ahead.
                @test DataFiles(dir_pin, DayAhead).EXCHANGE.EXCHANGE ≈ da_ex.EXCHANGE

                # Day-ahead net positions are NTC-capped at ±40 (Z2 exports to Z1).
                @test maximum(abs, da_ex.EXCHANGE) ≈ 40.0 atol=1e-6

                # Teeth: unpinned, redispatch moves the net positions (the wind recall at
                # n3 in Z2 paired with gas coming down at n1 in Z1 is a cross-zonal shift).
                @test any(abs(zone_np(ni_free, z, t) - da_np(z, t)) > 1.0 for z in Z, t in T)

                # Pinned: every zone, every hour, exactly at its day-ahead value.
                for z in Z, t in T
                    @test zone_np(ni_pin, z, t) ≈ da_np(z, t) atol=1e-6
                end

                # Case 3's congestion is only relievable across the zonal border, so the
                # pin forces the model off the recall solution and onto lost load.
                @test sum(free.NodalMarketRedispBalance.LL) ≈ 0.0 atol=1e-6
                @test sum(pinned.NodalMarketRedispBalance.LL) > 1e-6
                @test sum(ndisp_rows(pinned).GEN_UP) < sum(ndisp_rows(free).GEN_UP)

                # The pin is softened by a slack pair, but at the default np_cost (50000)
                # it sits above every other escape (CU/LL 9000, storage 10000): the pin
                # holds exactly and the reported slack is identically zero. That is what
                # makes the exact-equality assertions above meaningful.
                np_inf = DataFiles(dir_pin, Redispatch).NP_INF
                @test !isempty(np_inf)
                @test Set(np_inf.index) == Set(Z)
                @test nrow(np_inf) == length(Z) * length(T)
                @test all(x -> abs(x) < 1e-6, np_inf.NP_INF_POS)
                @test all(x -> abs(x) < 1e-6, np_inf.NP_INF_NEG)
                @test all(x -> abs(x) < 1e-6, np_inf.NP_INF)
                # NP_DA carries the day-ahead value each zone was pinned to.
                for row in eachrow(np_inf)
                    @test row.NP_DA ≈ da_np(row.index, row.Time) atol=1e-6
                end
                # This run does have lost load (asserted above), so the report is not
                # empty — but no net-position violation is part of it.
                pinned_report = with_logger(logger) do
                    check_infeasibility(pinned)
                end
                @test !("NP_INF" in pinned_report.source)

                # The unpinned run builds no such constraint and no such table.
                @test isempty(DataFiles(dir_free, Redispatch).NP_INF)
            end
        end

        # =================================================================
        @testset "net position slack relaxes an unaffordable pin" begin
            mktempdir() do tmpdir
                # Price the pin below the CU/LL slack (9000) and below the lost load the
                # default-priced pin was forced onto above: relaxing the net position now
                # beats shedding load, so the slack must actually take a non-zero value.
                cheap = run_redisp(tmpdir, "np_cheap", DCLF(; fix_net_positions = true, np_cost = 100.0))

                np_inf = DataFiles(joinpath(tmpdir, "np_cheap"), Redispatch).NP_INF
                @test sum(np_inf.NP_INF_POS) + sum(np_inf.NP_INF_NEG) > 1e-6
                # Slack halves are complementary — never both non-zero in the same row.
                @test all(row -> row.NP_INF_POS < 1e-6 || row.NP_INF_NEG < 1e-6, eachrow(np_inf))
                @test all(row -> row.NP_INF ≈ row.NP_INF_POS - row.NP_INF_NEG, eachrow(np_inf))

                # Relaxing beats shedding: no lost load left at this price.
                @test sum(cheap.NodalMarketRedispBalance.LL) ≈ 0.0 atol=1e-6

                # The realised net position is the pinned value plus the slack taken.
                ni = DataFiles(joinpath(tmpdir, "np_cheap"), Redispatch).NETINPUT
                for row in eachrow(np_inf)
                    @test zone_np(ni, row.index, row.Time) ≈ row.NP_DA + row.NP_INF atol=1e-6
                end

                # check_infeasibility must surface it rather than report a clean run.
                report = with_logger(logger) do
                    check_infeasibility(cheap)
                end
                @test "NP_INF" in report.source
                @test sum(filter(r -> r.source == "NP_INF", report).total) ≈
                      sum(np_inf.NP_INF_POS) + sum(np_inf.NP_INF_NEG) atol=1e-6
            end
        end

        # =================================================================
        @testset "net position pinning under a nodal market" begin
            # Covers the NodalMarket branch of `zonal_net_position`, which derives the
            # day-ahead net position from nodal NETINPUT because a nodal market has no
            # EXCHANGE table.
            mktempdir() do tmpdir
                with_logger(logger) do
                    setup = ModelSetup(
                        TimeHorizon     = TimeHorizon(stop=4),
                        MarketType      = NodalMarket(),
                        ProsumerSetup   = NoProsumer(),
                        RedispatchSetup = DCLF(; fix_net_positions = true),
                    )
                    mr = ModelRun(params, setup, solver;
                        resultdir=tmpdir, scenarioname="np_nodal", overwrite=true)
                    POMATWO.run(mr)
                end

                dir = joinpath(tmpdir, "np_nodal")
                ni_da = DataFiles(dir, DayAhead).NETINPUT
                ni_rd = DataFiles(dir, Redispatch).NETINPUT

                for z in params.sets.Z, t in 1:4
                    @test zone_np(ni_rd, z, t) ≈ zone_np(ni_da, z, t) atol=1e-6
                end
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
