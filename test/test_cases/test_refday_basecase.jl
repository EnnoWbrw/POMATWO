using Test
using DataFrames
using Dates
using Statistics

# Helper: minimal params for scope / shift tests
function create_refday_test_params()
    nodes = ["n1", "n2", "n3"]
    sets = POMATWO.Sets(N = nodes, Z = ["z1", "z2"])
    return POMATWO.Parameters(
        sets = sets,
        node2zone = Dict("n1" => "z1", "n2" => "z1", "n3" => "z2"),
        nodes_in_zone = Dict("z1" => ["n1", "n2"], "z2" => ["n3"]),
    )
end

# Helper: hand-built nodal data (3 nodes, 2 zones, 2 times) for shift tests
function create_refday_test_nd()
    return (
        nodes = ["n1", "n2", "n3"],
        times = [1, 2],
        RES  = Dict(("n1",1)=>4.0, ("n2",1)=>1.0, ("n3",1)=>8.0,
                    ("n1",2)=>6.0, ("n2",2)=>2.0, ("n3",2)=>5.0),
        CONV = Dict(("n1",1)=>8.0, ("n2",1)=>2.0, ("n3",1)=>15.0),
        gmax_conv = Dict("n1"=>20.0, "n2"=>10.0, "n3"=>30.0),
        gmax_res  = Dict("n1"=>10.0, "n2"=>5.0,  "n3"=>12.0),
        P    = Dict(("n1",1)=>10.0, ("n2",1)=>-5.0, ("n3",1)=>20.0,
                    ("n1",2)=>14.0, ("n2",2)=>0.0,  ("n3",2)=>15.0),
        LOAD = Dict(("n1",1)=>3.0, ("n2",1)=>6.0, ("n3",1)=>5.0,
                    ("n1",2)=>3.0, ("n2",2)=>6.0, ("n3",2)=>5.0),
        nodes_in_zone = Dict("z1" => ["n1", "n2"], "z2" => ["n3"]),
    )
end

# Helper: toy matchable generation frame (cluster_size = 1 → clusters 1..3)
# z1 (n1) profile [5,1,5]: cluster 3 ≡ cluster 1. z2 (n3) [2,7,7]: cluster 3 ≡ cluster 2.
function create_refday_test_genframe()
    toy = DataFrame(
        Time = [1,2,3, 1,2,3],
        GEN  = [5.0,1.0,5.0, 2.0,7.0,7.0],
        index = ["p1","p1","p1","p3","p3","p3"],
        node = ["n1","n1","n1","n3","n3","n3"],
        plant_type = fill("onwind", 6),
    )
    toy[!, :Cluster] = toy.Time
    toy[!, :IsWeekend] = fill(false, 6)
    return toy
end

function test_refday_basecase()
    params = create_refday_test_params()
    nd = create_refday_test_nd()
    NP_tgt(z) = sum(nd.P[(n, 2)] for n in nd.nodes_in_zone[z])

    check_np(p_new) = all(
        isapprox(sum(p_new[n] for n in znodes), NP_tgt(z); atol = 1e-6)
        for (z, znodes) in nd.nodes_in_zone
    )

    @testset "FlowBased config + basecase method selection" begin
        fb0 = FlowBased()
        fb1 = FlowBased(DispOnlyGSK())
        @test fb0.basecase isa OptimizationBasecase
        @test fb1.GSKStrategy isa DispOnlyGSK && fb1.basecase isa OptimizationBasecase

        rd = ReferenceDayBasecase(
            source = "results/forecast",
            matching = MatchingConfig(lookback = 4, scope = ZonalMatchScope()),
            shift = ShareShift(β_conv = 0.5, β_load = 0.5, res_prestep = true),
        )
        fb2 = FlowBased(GSKStrategy = DispOnlyGSK(), basecase = rd)
        @test fb2.basecase isa ReferenceDayBasecase
        @test fb2.basecase.source_type == ""   # default: regular market result tables
        @test fb2.basecase.matching.scope isa ZonalMatchScope

        mk(fb; kw...) = ModelSetup(TimeHorizon = TimeHorizon(stop = 24),
                                   MarketType = ZonalMarket(fb); kw...)
        @test state_sequence(mk(fb1)) == [TwoDayAhead, DayAhead]
        @test state_sequence(mk(fb2)) == [DayAhead]
        @test state_sequence(mk(fb1; RedispatchSetup = DCLF())) == [TwoDayAhead, DayAhead, Redispatch]
        @test state_sequence(mk(fb2; RedispatchSetup = DCLF())) == [DayAhead, Redispatch]
        # non-FBMC sequences untouched
        @test state_sequence(ModelSetup(TimeHorizon = TimeHorizon(stop = 24))) == [DayAhead]
    end

    @testset "GSKRedist: time-dependent strategy uses per-timestep GLSK weights" begin
        # GenLoadGSK weights from the forecast run's nodal data at t:
        # gen = P + load ; weight = |gen| + |load|
        # n1: P=10, load=3 → |13|+|3| = 16 ; n2: P=-5, load=6 → |1|+|6| = 7
        w = POMATWO._key_weights(GSKRedist(GenLoadGSK()), nd, params, ["n1", "n2"], 1)
        @test w == Dict("n1" => 16.0, "n2" => 7.0)

        # static strategies keep using the (optionally cached) GSK column
        wf = POMATWO._key_weights(GSKRedist(FlatGSK()), nd, params, ["n1", "n2"], 1)
        @test wf["n1"] ≈ 0.5 && wf["n2"] ≈ 0.5
    end

    @testset "MatchScope node partitions" begin
        gG = POMATWO.node_groups(GlobalMatchScope(), params)
        @test collect(keys(gG)) == ["ALL"] && gG["ALL"] == ["n1", "n2", "n3"]
        gZ = POMATWO.node_groups(ZonalMatchScope(), params)
        @test gZ["z1"] == ["n1", "n2"] && gZ["z2"] == ["n3"]
        gA = POMATWO.node_groups(AreaMatchScope(Dict("n1"=>"A","n2"=>"A","n3"=>"A")), params)
        @test length(gA) == 1 && gA["A"] == ["n1", "n2", "n3"]
        @test_throws ErrorException POMATWO.node_groups(AreaMatchScope(Dict("n1"=>"A")), params)
    end

    @testset "match_by_scope: independent per-zone matching" begin
        toy = create_refday_test_genframe()
        kw = (lookback = 2, keycols = [:plant_type], valuecols = [:GEN],
              value_methods = [median], weights = Dict{Symbol,Float64}(),
              exact_weekend = false)
        mz = match_by_scope(toy, ZonalMatchScope(), params; kw...)
        @test "group" in names(mz)
        r1 = only(filter(r -> r.group == "z1" && r.target_cluster == 3, mz)).matched_cluster
        r2 = only(filter(r -> r.group == "z2" && r.target_cluster == 3, mz)).matched_cluster
        @test r1 == 1   # z1's day 3 resembles day 1
        @test r2 == 2   # z2's day 3 resembles day 2
        # GlobalMatchScope reproduces plain global matching
        mg = match_by_scope(toy, GlobalMatchScope(), params; kw...)
        mc = match_by_cluster(toy; kw...)
        @test mg[:, [:target_time, :matched_time]] == mc[:, [:target_time, :matched_time]]
    end

    @testset "match_by_cluster: weekend relax fallback keeps coverage" begin
        toy = create_refday_test_genframe()
        toy[!, :IsWeekend] = [false, false, true, false, false, true]  # cluster 3 weekend, no weekend candidate
        m = @test_logs (:warn, r"relaxing exact_weekend") match_by_cluster(
            toy; lookback = 2, keycols = [:plant_type], valuecols = [:GEN],
            value_methods = [median], weights = Dict{Symbol,Float64}(), exact_weekend = true)
        @test 3 in m.target_cluster   # weekend cluster still matched
    end

    @testset "resolve_ref_times: group map, fallback, skip" begin
        sm = DataFrame(group = ["z1"], target_time = [3], matched_time = [1])
        fb = DataFrame(target_time = [3], matched_time = [2])
        refmap, skipped = POMATWO.resolve_ref_times(sm, ZonalMatchScope(), params, [3];
                                                    fallback_matches = fb)
        @test refmap[("n1", 3)] == 1 && refmap[("n2", 3)] == 1
        @test refmap[("n3", 3)] == 2          # z2 unmatched → global fallback
        @test isempty(skipped)
        _, skipped2 = POMATWO.resolve_ref_times(sm, ZonalMatchScope(), params, [3])
        @test skipped2 == [3]                 # no fallback → hour skipped
    end

    @testset "shift_single: NP closure invariant" begin
        for m in (
            ShareShift(β_conv=1.0, β_load=0.0, β_RES=0.0, β_NP=0.0,
                       resolution=:zonal, redist=RefPropRedist()),
            ShareShift(β_conv=1.0, β_load=0.0, β_RES=0.0, β_NP=0.0,
                       resolution=:zonal, res_prestep=true, redist=RefPropRedist()),
            ShareShift(β_conv=0.5, β_load=0.5, β_RES=0.0, β_NP=0.0,
                       resolution=:zonal, redist=LoadPropRedist()),
            ShareShift(β_conv=0.0, β_load=0.0, β_RES=0.0, β_NP=1.0,
                       resolution=:zonal, redist=RefPropRedist()),
        )
            @test check_np(POMATWO.shift_single(nd, params, 2, 1, m))
        end

        # nodal resolution reproduces the target nodal injection exactly
        mD = ShareShift(β_conv=0.5, β_load=0.5, resolution=:nodal, redist=RefPropRedist())
        pD = POMATWO.shift_single(nd, params, 2, 1, mD)
        @test all(isapprox(pD[n], nd.P[(n, 2)]; atol = 1e-6) for n in nd.nodes)

        # saturation cascade: tight conv headroom, gap still closes
        nd_tight = merge(nd, (gmax_conv = Dict("n1"=>9.0, "n2"=>3.0, "n3"=>16.0),))
        mE = ShareShift(β_conv=1.0, β_load=0.0, resolution=:zonal, redist=RefPropRedist())
        p_tight = POMATWO.shift_single(nd_tight, params, 2, 1, mE)
        @test all(isapprox(sum(p_tight[n] for n in znodes), NP_tgt(z); atol=1e-6)
                  for (z, znodes) in nd.nodes_in_zone)

        # per-node reference map (patchwork) — invariant still closes; map==scalar when constant
        mC = ShareShift(β_conv=0.5, β_load=0.5, resolution=:zonal, redist=LoadPropRedist())
        p_map = POMATWO.shift_single(nd, params, 2, Dict("n1"=>1,"n2"=>1,"n3"=>2), mC)
        @test check_np(p_map)
        p_s = POMATWO.shift_single(nd, params, 2, 1, mC)
        p_m = POMATWO.shift_single(nd, params, 2, Dict(n=>1 for n in nd.nodes), mC)
        @test all(isapprox(p_s[n], p_m[n]; atol=1e-12) for n in nd.nodes)
    end

    @testset "waterfill bounds and remainder" begin
        w = Dict("a"=>1.0, "b"=>1.0)
        lo = Dict("a"=>0.0, "b"=>0.0); hi = Dict("a"=>3.0, "b"=>3.0)
        ap, rem = POMATWO._waterfill(10.0, ["a","b"], w, lo, hi)
        @test ap["a"] ≈ 3.0 && ap["b"] ≈ 3.0 && rem ≈ 4.0
        # negative direction with room below
        ap2, rem2 = POMATWO._waterfill(-2.0, ["a","b"], w, Dict("a"=>-5.0,"b"=>-5.0), hi)
        @test ap2["a"] ≈ -1.0 && ap2["b"] ≈ -1.0 && abs(rem2) < 1e-9
        # lo = 0 blocks negative movement entirely → full remainder returned
        ap3, rem3 = POMATWO._waterfill(-2.0, ["a","b"], w, lo, hi)
        @test ap3["a"] == 0.0 && ap3["b"] == 0.0 && rem3 ≈ -2.0
    end

    @testset "validate_shares warnings" begin
        @test_logs (:warn, r"sum to") POMATWO.validate_shares(
            ShareShift(β_conv = 0.9, β_load = 0.0, β_RES = 0.0, β_NP = 0.0))
        @test_throws ErrorException POMATWO.validate_shares(
            ShareShift(resolution = :bogus))
    end

    @testset "shift_single trace: deltas complete and valid" begin
        valid_comps = Set(["RES_prestep", "RES", "conv", "load", "NP", "unabsorbed"])
        for m in (
            ShareShift(β_conv=1.0, β_load=0.0, β_RES=0.0, β_NP=0.0,
                       resolution=:zonal, redist=RefPropRedist()),
            ShareShift(β_conv=0.5, β_load=0.5, β_RES=0.0, β_NP=0.0,
                       resolution=:zonal, res_prestep=true, redist=LoadPropRedist()),
            ShareShift(β_conv=0.5, β_load=0.5, resolution=:nodal,
                       res_prestep=true, redist=RefPropRedist()),
            ShareShift(β_conv=0.0, β_load=0.0, β_RES=0.0, β_NP=1.0,
                       resolution=:zonal, redist=RefPropRedist()),
        )
            tr = POMATWO.ShiftTraceCollector()
            p = POMATWO.shift_single(nd, params, 2, 1, m; trace = tr)
            df = POMATWO.shift_trace_df(tr)

            @test all(abs.(df.delta) .> POMATWO.SHIFT_TRACE_TOL)
            @test all(in(valid_comps), df.component)
            @test all(==(2), df.Time)
            # prestep rows appear iff the pre-step is active
            @test ("RES_prestep" in df.component) == m.res_prestep
            # :NP always closes the cascade → no unabsorbed remainder
            @test !("unabsorbed" in df.component)

            # deltas are complete: p_new = P_ref + Σ deltas per node
            nodal = filter(:component => !=("unabsorbed"), df)
            for n in nd.nodes
                d = sum(nodal.delta[nodal.node .== n]; init = 0.0)
                @test isapprox(p[n], nd.P[(n, 1)] + d; atol = 1e-6)
            end
            # per-zone: Σ deltas = full net-position gap
            for (z, znodes) in nd.nodes_in_zone
                dz = sum(nodal.delta[in.(nodal.node, Ref(Set(znodes)))]; init = 0.0)
                gap = NP_tgt(z) - sum(nd.P[(n, 1)] for n in znodes)
                @test isapprox(dz, gap; atol = 1e-6)
            end

            # tracing does not change the result
            p_plain = POMATWO.shift_single(nd, params, 2, 1, m)
            @test all(isapprox(p[n], p_plain[n]; atol = 1e-12) for n in nd.nodes)
        end
    end

    @testset "resolve_group_times: fallback flags and skip" begin
        sm = DataFrame(group = ["z1"], target_time = [3], matched_time = [1])
        fb = DataFrame(target_time = [3], matched_time = [2])
        gm, skipped = POMATWO.resolve_group_times(sm, ZonalMatchScope(), params, [3];
                                                  fallback_matches = fb)
        @test isempty(skipped)
        rz1 = only(filter(:group => ==("z1"), gm))
        rz2 = only(filter(:group => ==("z2"), gm))
        @test rz1.matched_time == 1 && rz1.fallback == false
        @test rz2.matched_time == 2 && rz2.fallback == true   # z2 borrowed the global fallback
        # skipped hour contributes no rows at all
        gm2, skipped2 = @test_logs (:warn, r"unresolved") POMATWO.resolve_group_times(
            sm, ZonalMatchScope(), params, [3])
        @test skipped2 == [3] && isempty(gm2)
    end

    @testset "_refday_match_trace: metadata join" begin
        sm = DataFrame(group = ["z1"], target_time = [3], matched_time = [1],
                       target_cluster = [3], matched_cluster = [1], cluster_distance = [0.5])
        fb = DataFrame(target_time = [3], matched_time = [2],
                       target_cluster = [3], matched_cluster = [2], cluster_distance = [1.5])
        gm, _ = POMATWO.resolve_group_times(sm, ZonalMatchScope(), params, [3];
                                            fallback_matches = fb)
        mt = POMATWO._refday_match_trace(gm, sm, fb)
        @test nrow(mt) == 2
        rz1 = only(filter(:group => ==("z1"), mt))
        rz2 = only(filter(:group => ==("z2"), mt))
        @test rz1.matched_cluster == 1 && rz1.cluster_distance == 0.5
        @test rz2.matched_cluster == 2 && rz2.cluster_distance == 1.5   # metadata from fallback table
    end
end

# End-to-end: forecast run → refday run with 2 splits → trace files on disk → read-back
function test_refday_trace_e2e()
    @testset "refday trace end-to-end (write + read-back)" begin
        datapath = joinpath(@__DIR__, "..", "..", "examples", "test_data_3_nodes_v2_fbmc")
        data_files = Dict{Symbol,String}(
            :plants  => joinpath(datapath, "plants.csv"),
            :nodes   => joinpath(datapath, "nodes.csv"),
            :zones   => joinpath(datapath, "zones.csv"),
            :lines   => joinpath(datapath, "lines.csv"),
            :dclines => joinpath(datapath, "dclines.csv"),
            :demand  => joinpath(datapath, "nodal_load.csv"),
            :types   => joinpath(datapath, "planttypes.csv"),
            :avail   => joinpath(datapath, "avail.csv"),
        )
        solver = HiGHS.Optimizer
        params = load_data(data_files)
        tmpdir = mktempdir()  # no do-block: Arrow mmap blocks eager cleanup on Windows

        with_logger(NullLogger()) do
            # forecast run: provides the 2DA reference pool
            setup_fc = ModelSetup(
                TimeHorizon = TimeHorizon(stop = 4),
                MarketType  = ZonalMarket(FlowBased(DispOnlyGSK())),
            )
            mr_fc = ModelRun(params, setup_fc, solver;
                resultdir = tmpdir, scenarioname = "forecast", overwrite = true)
            POMATWO.run(mr_fc)

            # refday run over 2 splits (exercises per-subrun trace slicing)
            bc = ReferenceDayBasecase(
                source = joinpath(tmpdir, "forecast"), source_type = "2DA",
                matching = MatchingConfig(cluster_size = 2, lookback = 1,
                                          scope = ZonalMatchScope()),
                shift = ShareShift(β_conv = 0.5, β_load = 0.5, res_prestep = true,
                                   redist = GSKRedist(DispOnlyGSK())),
            )
            setup_rd = ModelSetup(
                TimeHorizon = TimeHorizon(stop = 4, split = 2),
                MarketType  = ZonalMarket(FlowBased(GSKStrategy = DispOnlyGSK(), basecase = bc)),
            )
            mr_rd = ModelRun(params, setup_rd, solver;
                resultdir = tmpdir, scenarioname = "refday", overwrite = true)
            POMATWO.run(mr_rd)

            scen = joinpath(tmpdir, "refday")

            # trace files: per-subrun slices + root groups table
            for sub in ("subrun_t1-t2", "subrun_t3-t4")
                @test isfile(joinpath(scen, sub, "REFDAY_MATCH.arrow"))
                @test isfile(joinpath(scen, sub, "REFDAY_SHIFT.arrow"))
            end
            @test isfile(joinpath(scen, "REFDAY_GROUPS.arrow"))

            # in-memory trace: reconstruction identity against the built basecase
            base = build_refday_basecase(bc, params)
            @test haskey(base, :trace)
            trace = base[:trace]
            src = DataFiles(joinpath(tmpdir, "forecast"); type = "2DA")
            P_src = Dict((r.index, r.Time) => r.ACINJECTION for r in eachrow(src.NETINPUT))
            reft = innerjoin(trace[:REFDAY_GROUPS], trace[:REFDAY_MATCH]; on = :group)
            refmap = Dict((r.node, r.target_time) => r.matched_time for r in eachrow(reft))
            shifts = trace[:REFDAY_SHIFT]
            for n in params.sets.N, t in 1:4
                d = sum(shifts.delta[(shifts.node .== n) .& (shifts.Time .== t)]; init = 0.0)
                @test isapprox(base[:netinput_ac][n, t], P_src[(n, refmap[(n, t)])] + d;
                               atol = 1e-6)
            end
            # no trace when disabled
            @test !haskey(build_refday_basecase(bc, params; collect_trace = false), :trace)

            # read-back through DataFiles
            out = DataFiles(scen)
            @test sort(unique(out.REFDAY_MATCH.target_time)) == [1, 2, 3, 4]
            @test nrow(unique(out.REFDAY_MATCH[:, [:group, :target_time]])) == nrow(out.REFDAY_MATCH)
            @test sort(unique(out.REFDAY_GROUPS.node)) == sort(params.sets.N)
            @test nrow(unique(out.REFDAY_GROUPS)) == nrow(out.REFDAY_GROUPS)
            @test !isempty(out.REFDAY_SHIFT)
            rt = refday_reference_times(out)
            @test nrow(rt) == length(params.sets.N) * 4

            # non-refday results read back with empty trace tables
            fc_out = DataFiles(joinpath(tmpdir, "forecast"))
            @test isempty(fc_out.REFDAY_MATCH) && isempty(fc_out.REFDAY_GROUPS) &&
                  isempty(fc_out.REFDAY_SHIFT)
            @test isempty(@test_logs (:warn, r"no reference-day trace") refday_reference_times(fc_out))
        end
    end
end
