market_types = [
    ZonalMarket(),
    NodalMarket(),
]

prosumer_setups = [
    NoProsumer(),
    ProsumerOptimization(sell_price=80.0, buy_price=250.0, retail_type=:buy_price),
    ProsumerOptimization(sell_price=90.0, buy_price=300.0, retail_type=:flat),
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

"""
Retail tariff types must actually behave differently.

The `:flat` tariff used to be `mean([min(price, 0) for t in T])`, which is identically 0
for any non-negative day-ahead price — so `:flat` and `:buy_price` produced identical
prosumer behaviour, and eight of the scenarios in the old grid were silent duplicates.
It is now the mean *non-negative* price. `netzentgelte` moved onto the setup at the same
time; all three prices are EUR/MWh, the unit `mc` uses everywhere else.
"""
function test_retail_types()
    @testset "Prosumer retail tariffs" begin
        solver = HiGHS.Optimizer
        params = load_data(cases["case 2"][:data_files])

        run_retail(rt, name, tmpdir; netzentgelte = 250.0) = with_logger(NullLogger()) do
            setup = ModelSetup(
                TimeHorizon     = TimeHorizon(stop = 4),
                MarketType      = ZonalMarket(),
                ProsumerSetup   = ProsumerOptimization(
                    sell_price = 80.0, buy_price = 250.0,
                    retail_type = rt, netzentgelte = netzentgelte),
                RedispatchSetup = NoRedispatch(),
            )
            mr = ModelRun(params, setup, solver;
                resultdir = tmpdir, scenarioname = name, overwrite = true)
            POMATWO.run(mr)
            sort(DataFiles(joinpath(tmpdir, name)).PRS, :Time)
        end

        tmpdir = mktempdir()

        # Day-ahead prices here are 7/7/7/25 EUR/MWh, so the flat tariff is their mean,
        # 11.5 — which is *below* the 80 EUR/MWh sell price. With the grid fee switched
        # off the two tariffs therefore imply opposite strategies: under `:buy_price`
        # (250) self-consumption is worth more than selling, under `:flat` it pays to sell
        # everything and buy the demand back. Before the fix `:flat` was identically 0,
        # so the two were indistinguishable.
        buy_free  = run_retail(:buy_price, "retail_buy_free", tmpdir; netzentgelte = 0.0)
        flat_free = run_retail(:flat, "retail_flat_free", tmpdir; netzentgelte = 0.0)

        @test sum(flat_free.PRS_BUY)  > sum(buy_free.PRS_BUY) + 1.0
        @test sum(flat_free.PRS_SELL) > sum(buy_free.PRS_SELL) + 1.0
        @test sum(flat_free.PRS_SELF) < sum(buy_free.PRS_SELF) - 1.0

        # A large enough grid fee swamps the difference between the two tariffs: both end
        # up far above the sell price, so the optimal behaviour coincides again.
        buy  = run_retail(:buy_price, "retail_buy", tmpdir)
        flat = run_retail(:flat, "retail_flat", tmpdir)
        @test sum(buy.PRS_BUY) ≈ sum(flat.PRS_BUY) atol = 1e-6

        # A grid fee is a cost on buying, so removing it can never reduce purchases.
        @test sum(buy_free.PRS_BUY) >= sum(buy.PRS_BUY) - 1e-6

        @test ProsumerOptimization(sell_price = 1.0).netzentgelte == 250.0
        @test ProsumerOptimization(sell_price = 1.0).self_discharge == 0.999
        @test_throws ErrorException ProsumerOptimization(sell_price = 1.0, retail_type = :nope)
    end
end
