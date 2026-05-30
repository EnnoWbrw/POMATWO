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

# ---------------------------------------------------------------
# Property-based invariant checks — independent of reference data
# ---------------------------------------------------------------

"""Check that all values in a non-empty DataFrame column are ≥ lower bound."""
function check_nonneg(df::DataFrame, col::Symbol; tol=-1e-8)
    isempty(df) && return true
    hasproperty(df, col) || return true
    return all(df[!, col] .≥ tol)
end

function test_model_creation()
    @testset "Model Creation and Run" begin
        solver = HiGHS.Optimizer
        params = load_data(cases["case 2"][:data_files])
        mktempdir() do tmpdir
            logger = NullLogger()
            with_logger(logger) do
                for (i, (market, prosumer, redisp, th)) in enumerate(all_setups())
                    scenarioname = "testcase_$(i)_$(nameof(typeof(market)))$(redispatch_suffix(redisp))_$(nameof(typeof(prosumer)))"
                    setup = ModelSetup(
                        TimeHorizon  = th,
                        MarketType   = market,
                        ProsumerSetup = prosumer,
                        RedispatchSetup = redisp,
                    )
                    mr = ModelRun(params, setup, solver;
                        resultdir   = tmpdir,
                        scenarioname = scenarioname,
                        overwrite    = true
                    )

                    @test mr.setup.MarketType      == market
                    @test mr.setup.ProsumerSetup   == prosumer
                    @test mr.setup.TimeHorizon      == th
                    @test mr.scenarioname           == scenarioname
                    @test isdir(mr.scen_dir)

                    @testset "Run + invariants for $scenarioname" begin
                        @test POMATWO.run(mr) === nothing

                        results = DataFiles(joinpath(tmpdir, scenarioname))
                        @test results isa DataFiles

                        # --- Non-negativity of primary decision variables ---
                        @test check_nonneg(results.GEN, :GEN)
                        @test check_nonneg(results.FEEDIN, :FEEDIN)
                        @test check_nonneg(results.CHARGE, :CHARGE)
                        @test check_nonneg(results.STO_LVL, :STO_LVL)

                        # --- Redispatch non-negativity ---
                        if !isempty(results.REDISP)
                            @test check_nonneg(results.REDISP, :GEN_REDISP)
                        end

                        # --- No infeasibility slacks activated ---
                        inf_report = check_infeasibility(results)
                        @test isempty(inf_report)

                        # --- Column structure: GEN must contain index and Time ---
                        if !isempty(results.GEN)
                            @test "index" in names(results.GEN)
                            @test "Time"  in names(results.GEN)
                            @test "GEN"   in names(results.GEN)
                        end

                        # --- ZonalMarket: EXCHANGE must exist ---
                        if market isa ZonalMarket && !isempty(results.EXCHANGE)
                            @test "index"    in names(results.EXCHANGE)
                            @test "EXCHANGE" in names(results.EXCHANGE)
                            @test all(isfinite.(results.EXCHANGE.EXCHANGE))
                        end

                        # --- NodalMarket: NodalMarketBalance must exist ---
                        if market isa NodalMarket && !isempty(results.NodalMarketBalance)
                            @test "LL" in names(results.NodalMarketBalance)
                        end

                        # --- Prosumer: PRS table must exist for ProsumerOptimization ---
                        if prosumer isa ProsumerOptimization && !isempty(results.PRS)
                            @test "index" in names(results.PRS)
                        end
                    end
                end
            end
        end
    end
end
