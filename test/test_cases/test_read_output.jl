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
                    ProsumerSetup   = ProsumerOptimization(sell_price=0.10, buy_price=0.25, retail_type=:buy_price),
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
        end  # mktempdir
    end  # testset
end
