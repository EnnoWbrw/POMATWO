market_types = [
    ZonalMarket(),
    NodalMarket(),
]



prosumer_setups = [
    NoProsumer(),
    ProsumerOptimization(sell_price=0.10, buy_price=0.25, retail_type=:buy_price),
    ProsumerOptimization(sell_price=0.15, buy_price=0.30, retail_type=:flat),
]

redispatch_setups = [
    NoRedispatch(),
    DCLF()
]

timehorizons = [
    TimeHorizon(stop=4),
    TimeHorizon(start=1, stop=4, split=2, offset=0),
]

redispatch_suffix(::NoRedispatch) = ""
redispatch_suffix(::DCLF)         = "WithRedispatch"

function all_setups()
    [(mt, ps, rd, th) for mt in market_types for rd in redispatch_setups for ps in prosumer_setups for th in timehorizons]
end

function compare_dataframes(df_actual, df_expected; atol=1e-6)
    @test size(df_actual) == size(df_expected)
    for col in names(df_expected)
        @test col in names(df_actual)
        if eltype(df_expected[!, col]) <: AbstractFloat
            @test all(abs.(df_actual[!, col] .- df_expected[!, col]) .<= atol)
        else
            @test df_actual[!, col] == df_expected[!, col]
        end
    end
end


function test_model_creation()
    @testset "Model Creation and Run" begin
        solver = HiGHS.Optimizer
        params = load_data(cases["case 2"][:data_files])
        mktempdir() do tmpdir
            logger = NullLogger()
            with_logger(logger) do
                for (i, (market, prosumer, redisp,th)) in enumerate(all_setups())
                    scenarioname = "testcase_$(i)_$(nameof(typeof(market)))$(redispatch_suffix(redisp))_$(nameof(typeof(prosumer)))"
                    setup = ModelSetup(
                        TimeHorizon =  th,
                        MarketType = market,
                        ProsumerSetup = prosumer,
                        RedispatchSetup = redisp,
                    )
                    run_dir = tmpdir
                    mr = ModelRun(params, setup, solver;
                        resultdir=run_dir,
                        scenarioname=scenarioname,
                        overwrite=true
                    )

                    @test mr.setup.MarketType == market
                    @test mr.setup.ProsumerSetup == prosumer
                    @test mr.setup.TimeHorizon == th
                    @test mr.scenarioname == scenarioname
                    @test isdir(mr.scen_dir)

                    @testset "Run model for $scenarioname" begin
                         @test POMATWO.run(mr) === nothing
                        @testset "reading results for $scenarioname and reference results" begin
                        results_actual = DataFiles(joinpath(run_dir, scenarioname))
                        expected_dir = joinpath(@__DIR__, "expected_results")
                        results_expected = DataFiles(joinpath(expected_dir, scenarioname))
                        @testset "Compare results for $scenarioname" begin
                        compare_dataframes(results_actual.GEN, results_expected.GEN)
                        compare_dataframes(results_actual.REDISP, results_expected.REDISP)
                        compare_dataframes(results_actual.CHARGE, results_expected.CHARGE)
                        compare_dataframes(results_actual.EXCHANGE, results_expected.EXCHANGE)
                        compare_dataframes(results_actual.FEEDIN, results_expected.FEEDIN)
                        compare_dataframes(results_actual.PRS, results_expected.PRS)
                        compare_dataframes(results_actual.LINEFLOW, results_expected.LINEFLOW)
                        compare_dataframes(results_actual.DCLINEFLOW, results_expected.DCLINEFLOW)
                        compare_dataframes(results_actual.NETINPUT, results_expected.NETINPUT)
                        compare_dataframes(results_actual.NTC, results_expected.NTC)
                        compare_dataframes(results_actual.STO_LVL, results_expected.STO_LVL)
                        compare_dataframes(results_actual.STO_LVL_REDISP, results_expected.STO_LVL_REDISP)
                        compare_dataframes(results_actual.ZonalMarketBalance, results_expected.ZonalMarketBalance)
                        compare_dataframes(results_actual.NodalMarketBalance, results_expected.NodalMarketBalance)
                        compare_dataframes(results_actual.NodalMarketRedispBalance, results_expected.NodalMarketRedispBalance)
                        end
                    end
                    end
                end
            end
        end
    end
end