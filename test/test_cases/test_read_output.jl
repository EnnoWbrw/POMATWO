"""
Tests for read_output.jl functions:
  - transform_results_by_type
  - summarize_result
  - get_redispatch_by_type_node
  - get_market_statistics
  - check_infeasibility

Uses real (minimal) model runs and mock DataFiles.
Does NOT depend on pre-computed expected_results directories.
"""

function test_read_output()
    @testset "Read Output Functions" begin
        solver = HiGHS.Optimizer

        # Load params for both cases
        params_no_prs   = load_data(cases["case 1"][:data_files])   # no prosumer
        params_with_prs = load_data(cases["case 2"][:data_files])   # with prosumer

        mktempdir() do tmpdir
            logger = NullLogger()

            # ── Run a minimal ZonalMarket / no-redispatch model ──────────────
            results_zonal = with_logger(logger) do
                setup = ModelSetup(
                    TimeHorizon     = TimeHorizon(stop=4),
                    MarketType      = ZonalMarket(),
                    ProsumerSetup   = NoProsumer(),
                    RedispatchSetup = NoRedispatch(),
                )
                mr = ModelRun(params_no_prs, setup, solver;
                    resultdir=tmpdir, scenarioname="ro_zonal", overwrite=true)
                POMATWO.run(mr)
                DataFiles(joinpath(tmpdir, "ro_zonal"))
            end

            # ── Run a ZonalMarket + Redispatch model ──────────────────────────
            results_redisp = with_logger(logger) do
                setup = ModelSetup(
                    TimeHorizon     = TimeHorizon(stop=4),
                    MarketType      = ZonalMarket(),
                    ProsumerSetup   = NoProsumer(),
                    RedispatchSetup = DCLF(),
                )
                mr = ModelRun(params_no_prs, setup, solver;
                    resultdir=tmpdir, scenarioname="ro_redisp", overwrite=true)
                POMATWO.run(mr)
                DataFiles(joinpath(tmpdir, "ro_redisp"))
            end

            # ── Run a NodalMarket / no-redispatch model ───────────────────────
            results_nodal = with_logger(logger) do
                setup = ModelSetup(
                    TimeHorizon     = TimeHorizon(stop=4),
                    MarketType      = NodalMarket(),
                    ProsumerSetup   = NoProsumer(),
                    RedispatchSetup = NoRedispatch(),
                )
                mr = ModelRun(params_no_prs, setup, solver;
                    resultdir=tmpdir, scenarioname="ro_nodal", overwrite=true)
                POMATWO.run(mr)
                DataFiles(joinpath(tmpdir, "ro_nodal"))
            end

            # ── Run a prosumer model ──────────────────────────────────────────
            results_prosumer = with_logger(logger) do
                setup = ModelSetup(
                    TimeHorizon     = TimeHorizon(stop=4),
                    MarketType      = ZonalMarket(),
                    ProsumerSetup   = ProsumerOptimization(sell_price=80.0, buy_price=250.0, retail_type=:buy_price),
                    RedispatchSetup = NoRedispatch(),
                )
                mr = ModelRun(params_with_prs, setup, solver;
                    resultdir=tmpdir, scenarioname="ro_prosumer", overwrite=true)
                POMATWO.run(mr)
                DataFiles(joinpath(tmpdir, "ro_prosumer"))
            end

            # =================================================================
            @testset "transform_results_by_type" begin
                zone = results_zonal.params.sets.Z[1]

                # :GEN and :DA must return the same result
                gen_by_type = transform_results_by_type(results_zonal, :GEN, zone)
                da_by_type  = transform_results_by_type(results_zonal, :DA,  zone)
                @test gen_by_type isa DataFrame
                @test da_by_type  isa DataFrame
                @test gen_by_type == da_by_type

                # Must have Time column and at least one plant-type column
                @test "Time" in names(gen_by_type)
                @test ncol(gen_by_type) >= 2          # Time + >=1 type
                @test nrow(gen_by_type) == 4          # 4 timesteps

                # :REDISP variant (only meaningful with redispatch)
                redisp_by_type = transform_results_by_type(results_redisp, :REDISP, zone)
                @test redisp_by_type isa DataFrame
                @test "Time" in names(redisp_by_type)

                # Unknown kind -> returns nothing
                @test transform_results_by_type(results_zonal, :UNKNOWN, zone) === nothing
            end

            # =================================================================
            @testset "summarize_result" begin
                zone = results_zonal.params.sets.Z[1]
                gen_by_type = transform_results_by_type(results_zonal, :GEN, zone)
                summary = summarize_result(gen_by_type)

                @test summary isa DataFrame
                @test nrow(summary) == 1
                @test "Time" ∉ names(summary)   # Time column dropped
                # Each type column: total should be >= 0
                for col in names(summary)
                    @test summary[1, col] >= -1e-8
                end
            end

            # =================================================================
            @testset "get_redispatch_by_type_node -- with redispatch" begin
                diff = get_redispatch_by_type_node(results_redisp)

                @test diff isa DataFrame
                @test !isempty(diff)

                required_cols = ["Time", "node", "type", "GEN", "GEN_REDISP", "difference"]
                for col in required_cols
                    @test col in names(diff)
                end

                # difference = GEN_REDISP - GEN
                for row in eachrow(diff)
                    @test row.difference ≈ row.GEN_REDISP - row.GEN atol=1e-8
                end

                # Sorted by (Time, node, type)
                @test issorted(diff, [:Time, :node, :type])

                # All values finite
                @test all(isfinite.(diff.GEN))
                @test all(isfinite.(diff.GEN_REDISP))
                @test all(isfinite.(diff.difference))

                # Nodes in output are valid nodes from params
                valid_nodes = results_redisp.params.sets.N
                @test all(n in valid_nodes for n in unique(diff.node))
            end

            # =================================================================
            @testset "get_redispatch_by_type_node -- no redispatch (empty)" begin
                diff_empty = get_redispatch_by_type_node(results_zonal)

                @test diff_empty isa DataFrame
                @test isempty(diff_empty)

                # Even empty, the columns must be present
                for col in ["Time", "node", "type", "GEN", "GEN_REDISP", "difference"]
                    @test col in names(diff_empty)
                end
            end

            # =================================================================
            @testset "get_market_statistics -- ZonalMarket" begin
                zone = results_zonal.params.sets.Z[1]
                stats = get_market_statistics(results_zonal, zone)

                @test stats isa DataFrame
                @test !isempty(stats)
                @test "metric"    in names(stats)
                @test "parameter" in names(stats)
                @test "value"     in names(stats)

                metrics = stats.metric
                @test "mean"   in metrics
                @test "median" in metrics
                @test "min"    in metrics
                @test "max"    in metrics
                @test "sum"    in metrics

                parameters = stats.parameter
                @test "Exchange"  in parameters
                @test "Lost_Load" in parameters
                @test "Price"     in parameters
            end

            # =================================================================
            @testset "get_market_statistics -- NodalMarket (empty EXCHANGE)" begin
                zone = results_nodal.params.sets.Z[1]
                stats = get_market_statistics(results_nodal, zone)

                @test stats isa DataFrame
                @test isempty(stats)
                @test "metric"    in names(stats)
                @test "parameter" in names(stats)
                @test "value"     in names(stats)
            end

            # =================================================================
            @testset "get_market_statistics -- unknown zone" begin
                stats = get_market_statistics(results_zonal, "NONEXISTENT_ZONE")
                @test stats isa DataFrame
                @test isempty(stats)
            end

            # =================================================================
            @testset "check_infeasibility -- feasible models" begin
                for (label, r) in [("zonal",    results_zonal),
                                   ("redisp",   results_redisp),
                                   ("nodal",    results_nodal),
                                   ("prosumer", results_prosumer)]
                    inf_report = check_infeasibility(r)
                    @test inf_report isa DataFrame
                    if !isempty(inf_report)
                        @warn "Infeasibility detected in $label" inf_report
                    end
                    @test isempty(inf_report)
                end
            end

            # =================================================================
            @testset "check_infeasibility -- detects mock LL violation" begin
                mock = create_mock_datafiles(
                    zones              = ["Z1", "Z2"],
                    zonal_balance_data = DataFrame(
                        Time          = [1, 2, 1, 2],
                        Zone          = ["Z1", "Z1", "Z2", "Z2"],
                        MarketBalance = [0.0, 0.0, 0.0, 0.0],
                        LL            = [0.0, 5.0, 0.0, 0.0],
                        CU            = [0.0, 0.0, 0.0, 0.0],
                    )
                )
                inf_report = check_infeasibility(mock)

                @test !isempty(inf_report)
                @test any(r -> r.variable == "LL", eachrow(inf_report))
                ll_row = filter(r -> r.variable == "LL", inf_report)[1, :]
                @test ll_row.count == 1
                @test ll_row.total ≈ 5.0
                @test ll_row.max   ≈ 5.0
            end

            # =================================================================
            @testset "check_infeasibility -- detects mock CU violation" begin
                mock = create_mock_datafiles(
                    zones              = ["Z1"],
                    zonal_balance_data = DataFrame(
                        Time          = [1, 2, 3, 4],
                        Zone          = fill("Z1", 4),
                        MarketBalance = zeros(4),
                        LL            = zeros(4),
                        CU            = [0.0, 0.0, 3.0, 7.0],
                    )
                )
                inf_report = check_infeasibility(mock)

                @test !isempty(inf_report)
                @test any(r -> r.variable == "CU", eachrow(inf_report))
                cu_row = filter(r -> r.variable == "CU", inf_report)[1, :]
                @test cu_row.count == 2
                @test cu_row.total ≈ 10.0
            end

            # =================================================================
            @testset "DataFiles -- RAM empty without flow-based coupling" begin
                # The :RAM table is only appended by add_exchange(::FlowBased);
                # NTC / nodal runs must read back an empty frame, not error.
                for r in (results_zonal, results_redisp, results_nodal, results_prosumer)
                    @test isempty(r.RAM)
                end
            end

            # =================================================================
            @testset "DataFiles -- split time horizon" begin
                results_split = with_logger(logger) do
                    setup = ModelSetup(
                        TimeHorizon     = TimeHorizon(start=1, stop=4, split=2, offset=0),
                        MarketType      = ZonalMarket(),
                        ProsumerSetup   = NoProsumer(),
                        RedispatchSetup = NoRedispatch(),
                    )
                    mr = ModelRun(params_no_prs, setup, solver;
                        resultdir=tmpdir, scenarioname="ro_split", overwrite=true)
                    POMATWO.run(mr)
                    DataFiles(joinpath(tmpdir, "ro_split"))
                end

                # Split horizon: 2 subruns -> GEN should still have 4 timesteps total
                @test !isempty(results_split.GEN)
                @test length(unique(results_split.GEN.Time)) == 4
            end

            # =================================================================
            # Per-market-state result files. Every stage writes under its own prefix
            # (`DayAhead_GEN.arrow`, ...), so the redispatch stage can no longer overwrite
            # the day-ahead's nodal tables the way it used to.
            @testset "DataFiles -- per-state result files" begin
                dir = joinpath(tmpdir, "ro_redisp")
                files = reduce(vcat, [readdir(d) for d in filter(isdir, readdir(dir, join=true))])
                arrows = filter(f -> endswith(f, ".arrow"), files)

                @test any(startswith(f, "DayAhead_") for f in arrows)
                @test any(startswith(f, "Redispatch_") for f in arrows)
                # nothing unprefixed survives from a stage
                @test !("GEN.arrow" in arrows)
                @test !("NETINPUT.arrow" in arrows)

                da = with_logger(logger) do; DataFiles(dir, DayAhead) end
                rd = with_logger(logger) do; DataFiles(dir, Redispatch) end

                # both stages write nodal tables: the redispatch stage from its DCLF, the
                # zonal day-ahead computed from the cleared dispatch (report_nodal_flows!)
                @test !isempty(da.NETINPUT)
                @test !isempty(da.GEN)
                @test !isempty(rd.NETINPUT)
                @test !isempty(rd.REDISP)
                @test isempty(rd.GEN)          # the redispatch stage writes no GEN table

                # the composite default keeps the pre-change view: GEN from the day-ahead,
                # the nodal tables from the last stage that wrote them. Reloaded because
                # earlier testsets mutate `results_redisp.GEN` in place.
                fresh = with_logger(logger) do; DataFiles(dir) end
                @test isequal(fresh.GEN, da.GEN)
                @test isequal(fresh.NETINPUT, rd.NETINPUT)

                # a *nodal* day-ahead does persist them, and both stages are now readable
                ndir = joinpath(tmpdir, "ro_nodal")
                nda = with_logger(logger) do; DataFiles(ndir, DayAhead) end
                @test !isempty(nda.NETINPUT)
            end

            # =================================================================
            @testset "DataFiles -- state dispatch, aliases and bad names" begin
                dir = joinpath(tmpdir, "ro_redisp")
                by_type  = with_logger(logger) do; DataFiles(dir, Redispatch) end
                by_alias = with_logger(logger) do; DataFiles(dir; type = "REDISP") end
                by_name  = with_logger(logger) do; DataFiles(dir; type = "Redispatch") end
                @test isequal(by_type.NETINPUT, by_alias.NETINPUT)
                @test isequal(by_type.NETINPUT, by_name.NETINPUT)

                @test POMATWO.result_prefix(Redispatch) == "Redispatch"
                @test POMATWO.market_state_type("2DA") === TwoDayAhead
                @test POMATWO.market_state_type("DA") === DayAhead
                @test POMATWO.trymarket_state_type("BIL") === nothing
                @test_throws ErrorException DataFiles(dir; type = "NotAState")
            end

            # =================================================================
            @testset "DataFiles -- BIL_EXCHANGE is readable" begin
                # Regression: the table was renamed from NTC to BIL_EXCHANGE but DataFiles
                # kept only the old field, so bilateral exchange could not be read at all.
                @test hasproperty(results_zonal, :BIL_EXCHANGE)
                # this dataset has a single zone, so there are no zone pairs to exchange
                # between; the table must still load with its schema rather than be absent
                @test issubset(["From", "To", "Time", "BIL_EXCHANGE"],
                               names(results_zonal.BIL_EXCHANGE))
                @test isfile(joinpath(tmpdir, "ro_zonal", "subrun_t1-t4",
                                      "DayAhead_BIL_EXCHANGE.arrow"))
            end

            # =================================================================
            @testset "DataFiles -- legacy result directories still load" begin
                # A directory holding no stage-prefixed file is read under the old names.
                legacy = mkpath(joinpath(tmpdir, "ro_legacy", "subrun_t1-t4"))
                Arrow.write(joinpath(legacy, "GEN.arrow"),
                            DataFrame(index = ["p1"], Time = [1], GEN = [10.0]))
                Arrow.write(joinpath(legacy, "NETINPUT.arrow"),
                            DataFrame(index = ["n1"], Time = [1], NETINPUT = [-10.0]))
                Arrow.write(joinpath(legacy, "2DANETINPUT.arrow"),
                            DataFrame(index = ["n1"], Time = [1], NETINPUT = [-99.0]))
                Arrow.write(joinpath(legacy, "NTC.arrow"),
                            DataFrame(From = ["Z1"], To = ["Z2"], Time = [1], BIL_EXCHANGE = [5.0]))

                dir = joinpath(tmpdir, "ro_legacy")
                old = with_logger(logger) do; DataFiles(dir) end
                @test old.GEN.GEN == [10.0]
                @test old.NETINPUT.NETINPUT == [-10.0]
                @test old.NTC.BIL_EXCHANGE == [5.0]          # legacy field still populated
                @test old.BIL_EXCHANGE.BIL_EXCHANGE == [5.0] # and reachable under the new name

                # the basecase is still addressable, and is NOT confused with the day-ahead
                bc = with_logger(logger) do; DataFiles(dir, TwoDayAhead) end
                @test bc.NETINPUT.NETINPUT == [-99.0]

                # a legacy stage request falls back to the unprefixed files
                rd = with_logger(logger) do; DataFiles(dir, Redispatch) end
                @test rd.NETINPUT.NETINPUT == [-10.0]

                # ... but a basecase request on a directory that has none must stay empty
                bare = mkpath(joinpath(tmpdir, "ro_legacy2", "subrun_t1-t4"))
                Arrow.write(joinpath(bare, "GEN.arrow"),
                            DataFrame(index = ["p1"], Time = [1], GEN = [1.0]))
                empty_bc = with_logger(logger) do
                    DataFiles(joinpath(tmpdir, "ro_legacy2"), TwoDayAhead)
                end
                @test isempty(empty_bc.GEN)
            end
        end  # mktempdir
    end  # testset
end
