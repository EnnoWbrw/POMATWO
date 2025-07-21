using Logging
market_types = [
    ZonalMarket(),
    ZonalMarketWithRedispatch(),
    NodalMarket(),
    NodalMarketWithRedispatch(),
]

prosumer_setups = [
    NoProsumer(),
    ProsumerOptimization(sell_price=0.10, buy_price=0.25, retail_type=:buy_price),
    ProsumerOptimization(sell_price=0.15, buy_price=0.30, retail_type=:flat),
]

timehorizons = [
    TimeHorizon(stop=4),
    TimeHorizon(start=1, stop=4, split=2, offset=0),
]

function all_setups()
    [(mt, ps, th) for mt in market_types for ps in prosumer_setups for th in timehorizons]
end
function test_model_creation()
    @testset "Model Creation and Run" begin
        solver = HiGHS.Optimizer
        params = load_data(cases["case 2"][:data_files])
        mktempdir() do tmpdir
            logger = NullLogger()
            with_logger(logger) do
                for (i, (market, prosumer, th)) in enumerate(all_setups())
                    scenarioname = "testcase_$(i)_$(nameof(typeof(market)))_$(nameof(typeof(prosumer)))"
                    setup = ModelSetup(
                        scenarioname,
                        th,
                        market,
                        prosumer
                    )
                    run_dir = joinpath(tmpdir, "results")
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
                    end
                end
            end
        end
    end
end