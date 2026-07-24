# Tests for the storage boundary condition at time-split edges
# (CarryOverStorage vs CyclicStorage).
#
# Scenario: 4 hours in 2 splits of 2 hours. Wind (200 MW) is only available in
# split 1, load is 100 MW in every hour, coal can only supply 50 MW. Serving the
# load in split 2 therefore REQUIRES energy stored during split 1 — possible with
# CarryOverStorage, impossible with CyclicStorage (levels do not cross splits).

function _storage_test_files()
    static = joinpath(@__DIR__, "data", "test_data_3_nodes_prosumer")
    dir = mktempdir()

    write(joinpath(dir, "plants.csv"), """
        index,plant_type,node,g_max,eta,storage_capacity,lat,lon,storage_power
        wind1,windnd,n1,200,1,0,49.0,9.0,
        coal1,coal,n2,50,1,0,51.0,10.0,
        psp1,psp,n1,100,1,300,49.5,9.5,100
        """)

    write(joinpath(dir, "planttypes.csv"), """
        index,dispatchable,storage,fuel_price,co2content,prosumer,color
        coal,1,0,25,0,0,#754937
        windnd,0,0,0,0,0,#518696
        psp,1,1,3,0,0,#0000ff
        """)

    write(joinpath(dir, "nodal_load.csv"), """
        n2
        100
        100
        100
        100
        """)

    write(joinpath(dir, "avail.csv"), """
        wind1
        1.0
        1.0
        0.0
        0.0
        """)

    return Dict{Symbol,String}(
        :plants => joinpath(dir, "plants.csv"),
        :types => joinpath(dir, "planttypes.csv"),
        :demand => joinpath(dir, "nodal_load.csv"),
        :avail => joinpath(dir, "avail.csv"),
        :nodes => joinpath(static, "nodes.csv"),
        :zones => joinpath(static, "zones.csv"),
        :lines => joinpath(static, "lines.csv"),
        :dclines => joinpath(static, "dclines.csv"),
    )
end

function test_storage_boundary()
    @testset "Storage boundary conditions" begin
        solver = HiGHS.Optimizer
        params = load_data(_storage_test_files())
        @test params.sets.S == ["psp1"]

        run_with(boundary, name, tmpdir) = begin
            setup = ModelSetup(
                TimeHorizon = TimeHorizon(stop = 4, split = 2),
                MarketType = ZonalMarket(),
                StorageBoundary = boundary,
            )
            mr = ModelRun(params, setup, solver;
                resultdir = tmpdir, scenarioname = name, overwrite = true)
            POMATWO.run(mr)
            return DataFiles(joinpath(tmpdir, name))
        end

        tmpdir = mktempdir()  # no do-block: Arrow mmap blocks eager cleanup on Windows
        with_logger(NullLogger()) do

            @testset "CarryOverStorage: levels cross splits" begin
                results = run_with(CarryOverStorage(), "carryover", tmpdir)

                # storage bridges the splits: no lost load anywhere
                @test sum(results.ZonalMarketBalance.LL) ≈ 0 atol = 1e-6
                @test isempty(check_infeasibility(results))

                sto = sort(filter(r -> r.index == "psp1", results.STO_LVL), :Time)
                gen = sort(filter(r -> r.index == "psp1", results.GEN), :Time)
                charge = sort(filter(r -> r.index == "psp1", results.CHARGE), :Time)

                # split 1 stores the energy needed in split 2 (2h * 100 MW)
                @test sto.STO_LVL[2] ≈ 200 atol = 1e-6
                # continuity at the split boundary: lvl(t3) = lvl(t2) - GEN(t3) + CHARGE(t3)
                @test sto.STO_LVL[3] ≈ sto.STO_LVL[2] - gen.GEN[3] + charge.CHARGE[3] atol = 1e-6
                # storage discharges 200 MWh in split 2
                @test gen.GEN[3] + gen.GEN[4] ≈ 200 atol = 1e-6
            end

            @testset "CarryOverStorage: start_share sets initial level" begin
                results = run_with(CarryOverStorage(start_share = 0.5), "startshare", tmpdir)
                sto = sort(filter(r -> r.index == "psp1", results.STO_LVL), :Time)
                gen = sort(filter(r -> r.index == "psp1", results.GEN), :Time)
                charge = sort(filter(r -> r.index == "psp1", results.CHARGE), :Time)
                # first hour starts from 0.5 * 300 = 150 MWh
                @test sto.STO_LVL[1] ≈ 150 - gen.GEN[1] + charge.CHARGE[1] atol = 1e-6
            end

            @testset "CyclicStorage: splits are independent, split 2 is short" begin
                results = run_with(CyclicStorage(), "cyclic", tmpdir)
                # without carry-over the stored wind energy cannot reach split 2:
                # at least 50 MW load is lost in each hour of split 2
                ll = sort(filter(r -> r.Time in (3, 4), results.ZonalMarketBalance), :Time)
                @test all(ll.LL .>= 50 - 1e-6)
                # split 1 remains fully served
                ll1 = filter(r -> r.Time in (1, 2), results.ZonalMarketBalance)
                @test sum(ll1.LL) ≈ 0 atol = 1e-6
            end

            @testset "invalid start_share" begin
                @test_throws ErrorException CarryOverStorage(start_share = 1.5)
            end

            # =========================================================================
            # Prosumer storage used to hardcode a cyclic-per-split level and a 0.9
            # round-trip efficiency, ignoring `StorageBoundary` and the plant's own `eta`.
            @testset "prosumer storage honours StorageBoundary and eta" begin
                prs_params = load_data(cases["case 2"][:data_files])
                @test prs_params.sets.PRS_STO == ["prs_n2"]
                eta = prs_params.eta["prs_n2"]

                run_prs(boundary, name; self_discharge = 0.999) = begin
                    setup = ModelSetup(
                        TimeHorizon = TimeHorizon(stop = 4, split = 2),
                        MarketType = ZonalMarket(),
                        ProsumerSetup = ProsumerOptimization(
                            sell_price = 80.0, buy_price = 250.0,
                            self_discharge = self_discharge),
                        StorageBoundary = boundary,
                    )
                    mr = ModelRun(prs_params, setup, solver;
                        resultdir = tmpdir, scenarioname = name, overwrite = true)
                    POMATWO.run(mr)
                    sort(DataFiles(joinpath(tmpdir, name)).PRS, :Time)
                end

                cyc = run_prs(CyclicStorage(), "prs_cyclic")
                car = run_prs(CarryOverStorage(), "prs_carry")

                lvl(df, t) = only(filter(r -> r.Time == t, df)).PRS_STO_LVL
                sto_in(df, t) = only(filter(r -> r.Time == t, df)).PRS_STO_IN
                sto_out(df, t) = only(filter(r -> r.Time == t, df)).PRS_STO_OUT
                bal(df, t, prev) =
                    0.999 * prev + eta * sto_in(df, t) - sto_out(df, t) / eta

                # CyclicStorage: each split wraps onto itself (t1 <- t2, t3 <- t4)
                @test lvl(cyc, 1) ≈ bal(cyc, 1, lvl(cyc, 2)) atol = 1e-6
                @test lvl(cyc, 3) ≈ bal(cyc, 3, lvl(cyc, 4)) atol = 1e-6

                # CarryOverStorage: the second split starts from where the first ended,
                # and the very first hour starts from start_share * capacity = 0
                @test lvl(car, 3) ≈ bal(car, 3, lvl(car, 2)) atol = 1e-6
                @test lvl(car, 1) ≈ bal(car, 1, 0.0) atol = 1e-6

                # self_discharge is honoured: with full retention the balance closes on 1.0
                keep = run_prs(CarryOverStorage(), "prs_nodecay"; self_discharge = 1.0)
                @test lvl(keep, 1) ≈ eta * sto_in(keep, 1) - sto_out(keep, 1) / eta atol = 1e-6

                @test_throws ErrorException ProsumerOptimization(
                    sell_price = 1.0, self_discharge = 1.5)
            end
        end
    end
end
